# FarRelay

FarRelay is a blind-first semantic remote computing platform for controlling machines, terminals, accessibility systems, and eventually agents through deterministic capabilities.

This repository originated from [ogomez92/nvdr](https://github.com/ogomez92/nvdr). FarRelay retains interoperability with the NVDA screen reader and the NVDA Remote relay protocol; those technical names remain where they describe the underlying technology rather than the product.

## Current capabilities

- FarRelay NVDA Bridge for NVDA Remote speech and input forwarding
- SSH-based relay bridge through `farrelay --ipc`
- Accessible interactive terminal support on Apple platforms
- `RemoteIntent` routing
- Cross-platform `farrelay-host` structured capability executable

`farrelay-host` accepts versioned NDJSON over standard input and currently exposes `host.info`, `process.list`, and `process.info`. On macOS it also advertises `voiceover.status`, `voiceover.move`, `voiceover.press`, and `voiceover.state` as implementation capabilities; those operations drive the Mac's real VoiceOver through a fixed AppleScript bridge rather than a FarRelay-owned screen reader. It has no arbitrary command execution, listener, daemon, or service-lifecycle API. See [FarRelay Host](docs/FARRELAY_HOST.md) and [macOS VoiceOver remote-control roadmap](docs/MACOS_VOICEOVER_REMOTE_ROADMAP.md).

## Future capabilities

Controller input, voice, a local Apple agent, ACP, MCP, OpenClaw/Jarvis, expanded semantic OS control, remote audio, and an Android semantic accessibility target are future work. They are not implemented in this repository today.

## Components

| Path | Purpose |
| --- | --- |
| `src/` + `Cargo.toml` | FarRelay Rust terminal client and `farrelay --ipc` bridge. |
| `farrelay-host/` | Cross-platform structured host executable. |
| `addon/` | FarRelay NVDA Bridge add-on. |
| `ios/`, `mac/` | Native FarRelay SwiftUI applications. |
| `android/` | Native FarRelay Android application. |

## Relay bridge

The Apple, Android, and NVDA add-on clients connect over SSH and invoke `farrelay --ipc` on a bridge machine. The bridge machine connects to the NVDA Remote relay using its established relay protocol; the executable rename does not change that wire protocol.

```text
client  ── SSH ──>  bridge machine: farrelay --ipc  ── TLS ──> NVDA Remote relay
```

Build the root client with `cargo build --release`; the executable is `target/release/farrelay`. Its TLS pins are stored at `~/.config/farrelay/known_hosts`. An existing `~/.config/nvdr/known_hosts` file is copied into the new location on first use when no FarRelay pin cache exists.

Run the structured host through SSH with:

```sh
ssh target farrelay-host
```

The structured host is separate from the existing relay bridge. It does not replace `ssh target farrelay --ipc`.

## Building clients

The Apple projects are generated from `project.yml` with XcodeGen. The Android project uses Gradle and requires JDK 17 plus Android SDK 36. See each platform directory for platform-specific setup.

## License

Same as the NVDA Remote project.
