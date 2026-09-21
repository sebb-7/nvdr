//! Long-running headless mode for driving farrelay from another process — built
//! for the NVDA add-on but usable by any controller. The wire format is plain
//! ASCII, line-oriented, so it's easy to drive from Python / a shell / netcat.
//!
//! # Stdin commands (one per line)
//!
//! - `key <vk> <pressed>` — raw VK transition. `vk` is a decimal u16 Windows
//!   virtual key code; `pressed` is `0` (release) or `1` (press). This is the
//!   path the NVDA add-on uses for passthrough — NVDA already hands us the VK
//!   per keystroke, so there's no point reparsing chord strings.
//! - `combo <spec>` — chord built from `keymap::parse_combo` syntax (e.g.
//!   `ctrl+alt+del`, `nvda+t`). Sends the full down/up sequence. NVDA defaults
//!   to Insert; pass `--nvda-key capslock` to swap.
//! - `type <text>` — paste literal text via the slave's clipboard. Escapes:
//!   `\n`, `\r`, `\\`.
//! - `sas` — send the secure-attention sequence (server-handled Ctrl+Alt+Del).
//! - `release_all` — emit key-up for every VK farrelay still considers held in
//!   this session, in reverse order. The add-on sends this when the user
//!   toggles passthrough off, so stray modifiers don't latch on the slave.
//! - `quit` — clean shutdown.
//!
//! Anything else is logged as `error bad command: …` and ignored. Closing
//! stdin is treated as `quit`.
//!
//! # Stdout events (one per line, the channel the controller actually parses)
//!
//! - `speak <text>` — speech text. Embedded `\n` / `\r` are replaced with
//!   spaces so the contract of "one event per line" holds.
//! - `cancel` — slave asked us to interrupt local speech.
//! - `state <name>` — lifecycle: `connecting`, `relay_connected`,
//!   `waiting_for_nvda`, `ready`, `disconnected`, `quit`. `ready` is emitted
//!   only while the joined channel contains an NVDA *slave* peer.
//! - `error <message>` — non-fatal error worth surfacing to the controller.
//! - `tone <hz> <milliseconds> <left> <right>` — a validated native NVDA
//!   tone. Levels are percentages and are clamped to the safe 0...100 range.
//! - `wave <basename.wav>` — a native NVDA wave reduced to a filename only;
//!   controllers must never use the remote path for local file access.
//!
//! Everything else (parse warnings, connect attempts, backoff timing) goes to
//! stderr where the add-on tees it into the NVDA log.

use std::io::Write;
use std::sync::Arc;

use anyhow::{anyhow, Result};
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use tokio::sync::Mutex;

use crate::keymap::{self, Transition};
use crate::protocol::{self, Inbound, Outbound};
use crate::transport;
use crate::vk;

const BACKOFF_MAX_MS: u64 = 30_000;

enum Cmd {
    Key(u16, bool),
    Combo(Vec<Transition>),
    Type(String),
    Sas,
    ReleaseAll,
    Quit,
}

enum SessionOutcome {
    Quit,
    Dropped(String),
    Fatal(anyhow::Error),
}

/// The relay does not make joining a channel equivalent to having an NVDA
/// endpoint. Keep the membership supplied by the protocol separate from the
/// transport lifetime so a channel with no peers (or masters only) can never
/// accept keyboard input.
#[derive(Debug, Default)]
struct ChannelMembership {
    peers: Vec<Value>,
    joined: bool,
    nvda_declared_unavailable: bool,
}

impl ChannelMembership {
    fn replace(&mut self, peers: Vec<Value>) {
        self.peers = peers;
        self.joined = true;
        self.nvda_declared_unavailable = false;
    }

    fn joined(&mut self, peer: Option<Value>) {
        if let Some(peer) = peer {
            self.remove_matching(&peer);
            if peer_connection_type(&peer) == Some("slave") {
                // A later successful slave join supersedes an earlier relay
                // `nvda_not_connected` hint.
                self.nvda_declared_unavailable = false;
            }
            self.peers.push(peer);
        }
    }

    fn left(&mut self, peer: Option<Value>, legacy_user_id: Option<u64>) {
        if let Some(peer) = peer {
            self.remove_matching(&peer);
        }
        if let Some(user_id) = legacy_user_id {
            self.remove_identity(&user_id.to_string());
        }
    }

    fn nvda_not_connected(&mut self) {
        self.nvda_declared_unavailable = true;
    }

    fn slave_count(&self) -> usize {
        self.peers
            .iter()
            .filter(|peer| peer_connection_type(peer) == Some("slave"))
            .count()
    }

    fn master_count(&self) -> usize {
        self.peers
            .iter()
            .filter(|peer| peer_connection_type(peer) == Some("master"))
            .count()
    }

    fn is_forwarding_ready(&self) -> bool {
        self.joined && !self.nvda_declared_unavailable && self.slave_count() > 0
    }

    fn remove_matching(&mut self, peer: &Value) {
        let key = peer_identity(peer);
        self.peers
            .retain(|candidate| match (&key, peer_identity(candidate)) {
                (Some(expected), Some(actual)) => expected != &actual,
                _ => candidate != peer,
            });
    }

    fn remove_identity(&mut self, identity: &str) {
        self.peers
            .retain(|candidate| peer_identity(candidate).as_deref() != Some(identity));
    }
}

fn peer_connection_type(peer: &Value) -> Option<&str> {
    peer.get("connection_type").and_then(Value::as_str)
}

/// Relay implementations have used object IDs, numeric `client` values, and
/// a separate legacy `user_id`. Normalize all of them so a disconnect can
/// always retire the matching peer instead of leaving a ghost slave behind.
fn peer_identity(peer: &Value) -> Option<String> {
    let value = ["id", "client_id", "clientId"]
        .iter()
        .find_map(|key| peer.get(*key))
        .unwrap_or(peer);
    if let Some(id) = value.as_u64() {
        return Some(id.to_string());
    }
    if let Some(id) = value.as_i64() {
        return Some(id.to_string());
    }
    value.as_str().map(str::to_owned)
}

fn channel_fingerprint(channel: &str) -> String {
    let digest = Sha256::digest(channel.as_bytes());
    digest[..8]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn emit_membership_state(membership: &ChannelMembership, channel: &str, host: &str, port: u16) {
    let state = if membership.is_forwarding_ready() {
        "ready"
    } else {
        "waiting_for_nvda"
    };
    emit_state(state);
    eprintln!(
        "farrelay-ipc: relay={host}:{port} joined={} peers={} slaves={} other_masters={} channel_sha256={}",
        membership.joined,
        membership.peers.len(),
        membership.slave_count(),
        membership.master_count(),
        channel_fingerprint(channel),
    );
}

pub async fn run(args: crate::Args) -> Result<()> {
    let channel = args
        .channel
        .clone()
        .ok_or_else(|| anyhow!("--ipc requires --channel; refusing to prompt interactively"))?;
    if channel.is_empty() {
        return Err(anyhow!("empty channel"));
    }

    let nvda_vk = vk::VK_INSERT; // `combo nvda+…` will resolve to Insert by default

    let host = args.host.clone();
    let port = args.port;
    let pin_path = args.pin_file.clone().or_else(transport::default_pin_path);

    let mut backoff_ms: u64 = 500;
    loop {
        emit_state("connecting");
        eprintln!("farrelay-ipc: connecting to {host}:{port}…");
        let conn = match transport::connect(
            &host,
            port,
            args.fingerprint.clone(),
            args.insecure,
            pin_path.clone(),
        )
        .await
        {
            Ok(c) => {
                backoff_ms = 500;
                c
            }
            Err(e) => {
                let msg = format!("{e:#}");
                if let Some(m) = crate::parse_pin_mismatch(&msg) {
                    emit_error(&format!(
                        "pin mismatch for {} (stored={} got={}); refusing to auto-accept in ipc mode — pin manually first",
                        m.host, m.stored, m.got
                    ));
                    emit_state("disconnected");
                    return Err(anyhow!("pin mismatch in ipc mode"));
                }
                emit_error(&format!("connect: {msg}"));
                emit_state("disconnected");
                crate::sleep_backoff(&mut backoff_ms, BACKOFF_MAX_MS).await;
                continue;
            }
        };

        match session(conn, &channel, &host, port, nvda_vk).await {
            SessionOutcome::Quit => {
                emit_state("quit");
                return Ok(());
            }
            SessionOutcome::Dropped(msg) => {
                eprintln!("farrelay-ipc: dropped: {msg}");
                emit_state("disconnected");
                crate::sleep_backoff(&mut backoff_ms, BACKOFF_MAX_MS).await;
            }
            SessionOutcome::Fatal(e) => {
                emit_error(&format!("fatal: {e:#}"));
                emit_state("disconnected");
                return Err(e);
            }
        }
    }
}

async fn session(
    conn: transport::TlsConn,
    channel: &str,
    host: &str,
    port: u16,
    nvda_vk: u16,
) -> SessionOutcome {
    let (reader, writer) = tokio::io::split(conn);
    let writer = Arc::new(Mutex::new(writer));

    if let Err(e) = crate::handshake(&writer, channel).await {
        return SessionOutcome::Dropped(format!("handshake: {e}"));
    }

    let (inbound_tx, mut inbound_rx) = mpsc::unbounded_channel::<Inbound>();
    let reader_task = tokio::spawn(crate::read_loop(reader, inbound_tx));

    let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<Cmd>();
    let stdin_task = tokio::spawn(stdin_loop(cmd_tx, nvda_vk));

    let mut held: Vec<u16> = Vec::new();
    let mut membership = ChannelMembership::default();

    let outcome = loop {
        tokio::select! {
            biased;
            msg = inbound_rx.recv() => {
                let Some(msg) = msg else {
                    break SessionOutcome::Dropped("reader closed".into());
                };
                // version_mismatch is fatal per spec §5.x — reconnecting won't help.
                if matches!(msg, Inbound::VersionMismatch) {
                    emit_error("version_mismatch: relay rejected protocol v2");
                    break SessionOutcome::Fatal(anyhow!("version mismatch"));
                }
                let was_forwarding_ready = membership.is_forwarding_ready();
                match &msg {
                    Inbound::ChannelJoined { clients, .. } => {
                        membership.replace(clients.clone());
                        emit_state("relay_connected");
                        emit_membership_state(&membership, channel, host, port);
                    }
                    Inbound::ClientJoined { client, .. } => {
                        membership.joined(client.clone());
                        if membership.joined {
                            emit_membership_state(&membership, channel, host, port);
                        }
                    }
                    Inbound::ClientLeft { client, user_id, .. } => {
                        membership.left(client.clone(), *user_id);
                        if membership.joined {
                            emit_membership_state(&membership, channel, host, port);
                        }
                    }
                    Inbound::NvdaNotConnected => {
                        membership.nvda_not_connected();
                        emit_membership_state(&membership, channel, host, port);
                    }
                    _ => {}
                }
                if was_forwarding_ready && !membership.is_forwarding_ready() {
                    // Losing the final slave is a forwarding boundary, not
                    // merely a cosmetic state change. Release modifiers while
                    // the relay writer still exists, then forget local state.
                    crate::release_held(&writer, &held).await;
                    held.clear();
                }
                emit_inbound(&msg);
            }
            cmd = cmd_rx.recv() => {
                let Some(cmd) = cmd else {
                    // Stdin closed — controller is gone; shut down cleanly.
                    break SessionOutcome::Quit;
                };
                match cmd {
                    Cmd::Key(vk, pressed) => {
                        if !membership.is_forwarding_ready() {
                            eprintln!("farrelay-ipc: key suppressed while waiting for NVDA");
                            continue;
                        }
                        eprintln!("farrelay-ipc: relay key vk={vk} pressed={pressed}");
                        let ts = [Transition { vk, pressed }];
                        crate::update_held(&mut held, &ts);
                        if let Err(e) = crate::send_keys(&writer, &ts).await {
                            break SessionOutcome::Dropped(format!("send key: {e}"));
                        }
                    }
                    Cmd::Combo(ts) => {
                        if !membership.is_forwarding_ready() {
                            eprintln!("farrelay-ipc: combo suppressed while waiting for NVDA");
                            continue;
                        }
                        crate::update_held(&mut held, &ts);
                        if let Err(e) = crate::send_keys(&writer, &ts).await {
                            break SessionOutcome::Dropped(format!("send combo: {e}"));
                        }
                    }
                    Cmd::Type(text) => {
                        if !membership.is_forwarding_ready() {
                            eprintln!("farrelay-ipc: type suppressed while waiting for NVDA");
                            continue;
                        }
                        if let Err(e) = crate::send(&writer, &Outbound::SetClipboardText { text: &text }).await {
                            break SessionOutcome::Dropped(format!("set_clipboard_text: {e}"));
                        }
                        let ts = crate::ctrl_v();
                        crate::update_held(&mut held, &ts);
                        if let Err(e) = crate::send_keys(&writer, &ts).await {
                            break SessionOutcome::Dropped(format!("ctrl+v: {e}"));
                        }
                    }
                    Cmd::Sas => {
                        if !membership.is_forwarding_ready() {
                            eprintln!("farrelay-ipc: SAS suppressed while waiting for NVDA");
                            continue;
                        }
                        if let Err(e) = crate::send(&writer, &Outbound::SendSas).await {
                            break SessionOutcome::Dropped(format!("sas: {e}"));
                        }
                    }
                    Cmd::ReleaseAll => {
                        let to_release: Vec<u16> = held.iter().rev().copied().collect();
                        let mut drop_err: Option<String> = None;
                        for vk in to_release {
                            let ts = [Transition::up(vk)];
                            crate::update_held(&mut held, &ts);
                            if let Err(e) = crate::send_keys(&writer, &ts).await {
                                drop_err = Some(format!("release_all: {e}"));
                                break;
                            }
                        }
                        if let Some(e) = drop_err {
                            break SessionOutcome::Dropped(e);
                        }
                    }
                    Cmd::Quit => break SessionOutcome::Quit,
                }
            }
        }
    };

    // Best-effort cleanup: drop any modifiers still down on the slave before
    // we let the writer half close, just like the interactive session does.
    crate::release_held(&writer, &held).await;
    {
        let mut w = writer.lock().await;
        let _ = w.shutdown().await;
    }
    reader_task.abort();
    stdin_task.abort();
    outcome
}

async fn stdin_loop(tx: mpsc::UnboundedSender<Cmd>, nvda_vk: u16) {
    let stdin = tokio::io::stdin();
    let mut reader = BufReader::new(stdin);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line).await {
            Ok(0) => return,
            Ok(_) => {
                let trimmed = line.trim_end_matches(['\r', '\n']);
                if trimmed.is_empty() {
                    continue;
                }
                eprintln!("farrelay-ipc: stdin got: {trimmed}");
                match parse_command(trimmed, nvda_vk) {
                    Ok(cmd) => {
                        let is_quit = matches!(cmd, Cmd::Quit);
                        if tx.send(cmd).is_err() {
                            return;
                        }
                        if is_quit {
                            return;
                        }
                    }
                    Err(e) => {
                        emit_error(&format!("bad command: {e}: {trimmed:?}"));
                    }
                }
            }
            Err(e) => {
                eprintln!("farrelay-ipc: stdin read: {e}");
                return;
            }
        }
    }
}

fn parse_command(line: &str, nvda_vk: u16) -> Result<Cmd, String> {
    let (head, rest) = line
        .split_once(char::is_whitespace)
        .map(|(a, b)| (a, b.trim_start()))
        .unwrap_or((line, ""));
    match head {
        "key" => {
            let mut it = rest.split_whitespace();
            let vk_s = it.next().ok_or_else(|| "key: missing vk".to_string())?;
            let pr_s = it
                .next()
                .ok_or_else(|| "key: missing pressed flag".to_string())?;
            let vk: u16 = vk_s.parse().map_err(|_| format!("key: bad vk {vk_s:?}"))?;
            let pressed = match pr_s {
                "0" => false,
                "1" => true,
                _ => return Err(format!("key: pressed must be 0 or 1, got {pr_s:?}")),
            };
            Ok(Cmd::Key(vk, pressed))
        }
        "combo" => {
            if rest.is_empty() {
                return Err("combo: empty spec".into());
            }
            let ts = keymap::parse_combo(rest, nvda_vk)?;
            Ok(Cmd::Combo(ts))
        }
        "type" => Ok(Cmd::Type(unescape(rest))),
        "sas" => Ok(Cmd::Sas),
        "release_all" => Ok(Cmd::ReleaseAll),
        "quit" => Ok(Cmd::Quit),
        _ => Err(format!("unknown command {head:?}")),
    }
}

fn unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c == '\\' {
            match it.next() {
                Some('n') => out.push('\n'),
                Some('r') => out.push('\r'),
                Some('t') => out.push('\t'),
                Some('\\') => out.push('\\'),
                Some(other) => {
                    // Unknown escape: keep both chars so user can see what they wrote.
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn emit_inbound(msg: &Inbound) {
    match msg {
        Inbound::Speak { sequence, .. } => {
            let text = protocol::speak_text(sequence);
            if !text.is_empty() {
                emit_speak(&text);
            }
        }
        Inbound::Cancel => emit_line("cancel"),
        // Membership has already emitted `waiting_for_nvda`. Do not emit the
        // legacy state after it or a controller could briefly re-enable input.
        Inbound::NvdaNotConnected => {}
        Inbound::Error { error } => {
            emit_error(error.as_deref().unwrap_or("(unspecified)"));
        }
        Inbound::Tone {
            hz,
            length,
            left,
            right,
        } => {
            if let Some(line) = tone_event_line(*hz, *length, *left, *right) {
                emit_line(&line);
            }
        }
        Inbound::Wave { file_name } => {
            if let Some(name) = file_name.as_deref().and_then(safe_wave_basename) {
                emit_line(&format!("wave {name}"));
            }
        }
        // Everything else is informational — leave the stdout channel clean.
        _ => {}
    }
}

fn tone_event_line(
    hz: Option<f64>,
    length: Option<f64>,
    left: Option<u32>,
    right: Option<u32>,
) -> Option<String> {
    let (hz, length, left, right) = (hz?, length?, left?, right?);
    if !hz.is_finite()
        || !length.is_finite()
        || !(20.0..=20_000.0).contains(&hz)
        || !(1.0..=5_000.0).contains(&length)
    {
        return None;
    }
    Some(format!(
        "tone {} {} {} {}",
        hz.round() as u32,
        length.round() as u32,
        left.min(100),
        right.min(100)
    ))
}

fn safe_wave_basename(remote: &str) -> Option<&str> {
    if remote.split(['/', '\\']).any(|part| part == "..") {
        return None;
    }
    let basename = remote.rsplit(['/', '\\']).next()?;
    if basename.is_empty()
        || basename == "."
        || basename == ".."
        || !basename.to_ascii_lowercase().ends_with(".wav")
    {
        return None;
    }
    Some(basename)
}

fn emit_speak(text: &str) {
    // Stdout contract is one event per line — collapse any embedded newlines
    // to spaces so a multi-line speech sequence still arrives as a single
    // `speak` event the controller can parse without state.
    let flat: String = text
        .chars()
        .map(|c| if c == '\n' || c == '\r' { ' ' } else { c })
        .collect();
    emit_line(&format!("speak {flat}"));
}

fn emit_state(name: &str) {
    emit_line(&format!("state {name}"));
}

fn emit_error(msg: &str) {
    let flat: String = msg
        .chars()
        .map(|c| if c == '\n' || c == '\r' { ' ' } else { c })
        .collect();
    emit_line(&format!("error {flat}"));
}

fn emit_line(s: &str) {
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(s.as_bytes());
    let _ = out.write_all(b"\n");
    let _ = out.flush();
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn master(id: u64) -> Value {
        json!({"id": id, "connection_type": "master"})
    }
    fn slave(id: u64) -> Value {
        json!({"id": id, "connection_type": "slave"})
    }

    #[test]
    fn empty_or_master_only_channel_waits_for_nvda() {
        let mut membership = ChannelMembership::default();
        membership.replace(vec![]);
        assert!(!membership.is_forwarding_ready());
        membership.replace(vec![master(1), master(2)]);
        assert!(!membership.is_forwarding_ready());
        assert_eq!(membership.master_count(), 2);
    }

    #[test]
    fn slave_membership_transitions_are_forwarding_safe() {
        let mut membership = ChannelMembership::default();
        membership.replace(vec![slave(1)]);
        assert!(membership.is_forwarding_ready());
        membership.joined(Some(slave(2)));
        membership.left(Some(slave(1)), None);
        assert!(membership.is_forwarding_ready());
        membership.left(Some(slave(2)), None);
        assert!(!membership.is_forwarding_ready());
    }

    #[test]
    fn late_slave_join_and_nvda_not_connected_are_handled_safely() {
        let mut membership = ChannelMembership::default();
        membership.replace(vec![]);
        membership.nvda_not_connected();
        assert!(!membership.is_forwarding_ready());
        membership.joined(Some(slave(3)));
        assert!(membership.is_forwarding_ready());
    }

    #[test]
    fn legacy_numeric_client_left_removes_slave_by_identity() {
        let mut membership = ChannelMembership::default();
        membership.replace(vec![slave(41)]);
        assert!(membership.is_forwarding_ready());
        membership.left(Some(json!(41)), None);
        assert!(!membership.is_forwarding_ready());
    }

    #[test]
    fn legacy_user_id_client_left_removes_slave_when_client_is_missing() {
        let mut membership = ChannelMembership::default();
        membership.replace(vec![slave(42)]);
        assert!(membership.is_forwarding_ready());
        membership.left(None, Some(42));
        assert!(!membership.is_forwarding_ready());
    }

    #[test]
    fn fresh_connection_membership_cannot_inherit_old_slaves() {
        let mut old_generation = ChannelMembership::default();
        old_generation.replace(vec![slave(9)]);
        assert!(old_generation.is_forwarding_ready());
        let new_generation = ChannelMembership::default();
        assert!(!new_generation.is_forwarding_ready());
    }

    #[test]
    fn channel_fingerprint_is_deterministic_and_does_not_echo_channel() {
        let fingerprint = channel_fingerprint("123456789");
        assert_eq!(fingerprint, channel_fingerprint("123456789"));
        assert_ne!(fingerprint, channel_fingerprint("123456789 "));
        assert!(!fingerprint.contains("123456789"));
    }

    #[test]
    fn native_tone_is_complete_bounded_and_preserved_in_ipc() {
        assert_eq!(
            tone_event_line(Some(440.0), Some(100.0), Some(50), Some(120)).as_deref(),
            Some("tone 440 100 50 100")
        );
        assert!(tone_event_line(Some(f64::NAN), Some(100.0), Some(50), Some(50)).is_none());
        assert!(tone_event_line(Some(440.0), None, Some(50), Some(50)).is_none());
    }

    #[test]
    fn native_wave_exposes_only_safe_basename() {
        assert_eq!(
            safe_wave_basename(r"C:\Program Files\NVDA\waves\browseMode.wav"),
            Some("browseMode.wav")
        );
        assert_eq!(
            safe_wave_basename("/usr/share/nvda/waves/focusMode.wav"),
            Some("focusMode.wav")
        );
        assert_eq!(safe_wave_basename("../../outside.wav"), None);
        assert_eq!(safe_wave_basename("not-a-wave.mp3"), None);
    }
}
