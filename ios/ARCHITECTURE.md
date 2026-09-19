# iOS connection architecture

## Before the SSH extraction

`BridgeClient` owned two different concerns:

- NVDA behavior: `farrelay --ipc` command construction, line-oriented IPC parsing,
  NVDA state mapping, speech forwarding, keyboard commands, forwarding state,
  and `releaseAll` on stop/disable.
- SSH transport: endpoint values, password/Ed25519/RSA authentication setup,
  custom RSA SHA-2 algorithm registration, Citadel connection lifecycle,
  exec-channel creation, and byte transport over stdin/stdout/stderr.

Authentication parsing and RSA/OpenSSH support lived beside the bridge driver,
which made the SSH path difficult to reuse for another remote host or protocol.

## After the SSH extraction

`BridgeClient` remains the NVDA-specific consumer. It creates the remote
`farrelay --ipc` command, maps settings into a plain `SSHSessionConfiguration`,
consumes generic SSH events as IPC text, and retains all forwarding and speech
semantics.

`SSHSession` owns generic SSH endpoint/authentication configuration, Citadel
connection and exec lifecycle, and a byte-oriented `SSHExecTransport`. The
transport exposes stdin writes and stdout/stderr events without exposing
Citadel or NIO types to `BridgeClient`.

`SSHSession` also offers a separate `withPTY` capability for interactive
remote login shells. `SSHExecTransport` remains the appropriate channel for
the structured `farrelay --ipc` protocol; `SSHPTYTransport` is for shells, tmux,
and interactive tools. A PTY exposes raw stdout/stderr bytes, exact input-byte
writes, and resize requests only—no UTF-8 decoding, ANSI/VT parsing, terminal
rendering, or reconnect behavior. Many SSH servers merge stderr into terminal
output once a PTY is allocated, so callers must treat the event distinction as
best-effort transport information. The supervisor recreates a dead PTY's
entire connected operation; it never resumes a PTY channel. Remote persistence
is an application concern (for example, tmux), not an SSH transport feature.

Long-lived work is run by `SSHConnectionSupervisor`, a generic lifecycle
layer over a reconnectable SSH connection. It distinguishes the user's desired
state (`running` or `stopped`) from the current transport state (`connecting`,
`connected`, `reconnecting`, `stopped`, or `failed`). A transient failure
closes the old connection and recreates both the SSH connection and the
connected operation; it never attempts to reuse a dead exec channel. This
keeps the abstraction reusable for a future PTY or another SSH-backed helper.

Each run and its active connection have a monotonically increasing generation.
Stop invalidates that generation before it awaits cleanup. A connection attempt
that returns after Stop is immediately closed and cannot emit `connected`, run
an operation, replace a newer connection, or update the UI. Citadel 0.12.1
does not make its socket client available before `SSHClient.connect` finishes,
so the app cannot publicly abort DNS/TCP/SSH negotiation at that abstraction.
The generation and session-attempt gates provide the safe fallback: late
successful clients are closed and never exposed.

The default reconnect policy uses unbounded retries while the user still wants
the session running, with a one-second initial delay, a doubling multiplier,
and a 30-second cap. Stop and task cancellation cancel pending retry sleep and
close the active connection, so they cannot cause a reconnect. Retry decisions
are typed and conservative: host identity, authentication, malformed-key,
and unknown protocol/configuration failures fail closed, while typed NIO
channel/IO and Citadel channel-loss failures may reconnect.

`SSHSession` also owns credential retrieval and host-key validation. SSH
secrets live in the device-local Keychain, while non-secret host identities
are persisted separately by normalized host and port. The normal policy is
trust on first use: a first key is stored, while any later key change fails
closed. Insecure key acceptance remains available only as an explicit policy.
Every recreated SSH connection performs this normal host-key validation; a
previous successful connection never bypasses TOFU.

For first use, the host-key validator accepts the presented key only for the
in-flight SSH handshake and defers durable trust storage until Citadel has
returned a connected client and the attempt gate is still valid. If Stop wins
while first-use validation is in flight, the gate rejects validation or the
deferred commit and no new trust record is written. A fingerprint that already
existed is never removed or changed by cancellation.

`BridgeClient` creates a new `farrelay --ipc` exec channel for every connected
operation. Its input stream is scoped to that channel and is finished whenever
the channel disconnects, so keystrokes typed while disconnected are dropped
rather than queued or replayed. The new channel receives `release_all` before
keyboard forwarding is enabled, and local pressed-key state is cleared at each
disconnect/reconnect boundary.

Hardware key-down auto-repeat is intentionally preserved: every accepted
key-down is forwarded, while a key-up is forwarded only when the current
channel still knows that key as held. Resetting that knowledge on disconnect
drops late releases from an obsolete channel without breaking normal repeated
arrows, backspace, letters, or navigation keys.

The `farrelay --ipc` protocol has a meaningful clean end: `state quit` follows a
remote `quit` command or stdin closing. `BridgeClient` reports that as an
intentional connected-operation completion, so the generic supervisor stops
without reconnecting. A returned exec stream without that completion remains
an unexpected operation end and follows the normal typed retry policy.

Citadel 0.12.1 and the resolved Swift-NIO-SSH 0.3.6 do not expose a public
client-side SSH global-request/keepalive sender. The transport therefore does
not implement a fake shell or IPC keepalive; normal socket/channel loss drives
the lifecycle instead. iOS background suspension is not overridden. If a
suspended or route-changed socket later fails when the app runs again, the
desired session may reconnect through the same bounded policy.

`SSHSession.authenticationSummary(for:)` is the synchronous, network-free
validation seam for authentication selection and key parsing. Lifecycle,
backoff, cancellation, retry classification, and disconnected-input behavior
also have deterministic in-memory unit coverage. CI compiles and runs these
tests on an iOS simulator, but does not connect to a real SSH host or inject a
real network interruption.

## SSH terminal coordination

`SSHTerminalSession` is the only layer that composes `SSHPTYTransport` with
`TerminalEngine`. It owns one cancellable PTY read task, hops every raw stdout
or stderr byte chunk to the main actor, and exposes only immutable
`TerminalSnapshot` values plus a small lifecycle state to future presentation
code. It does not expose Citadel, NIO, or SwiftTerm internals.

The coordinator passes input bytes through unchanged. On resize it validates
the requested PTY dimensions, updates `TerminalEngine` first, then awaits the
remote PTY resize. Updating locally first gives presentation an immediate,
deterministic snapshot at the requested size while the remote request is in
flight. A transport failure transitions the session to `failed`; a remote EOF
transitions it to `ended`; and `close()` is idempotent, cancels the read task,
and lets the surrounding `SSHSession.withPTY` operation end the channel scope.

## Terminal accessibility interpretation

`TerminalEngine` remains the sole owner of terminal parsing and mutable buffer
state. `TerminalAccessibilityModel` consumes only its immutable
`TerminalSnapshot` values and derives presentation-neutral logical lines,
visible content, and bounded semantic change events. It has no SSH, Citadel,
NIO, SwiftTerm, UI, VoiceOver, NVDA, or speech dependency.

The model joins rows marked by the engine as soft-wrap continuations so future
assistive presentation can read logical content without terminal-width-only
breaks. It treats a size change or non-append rewrite as one `screenReplaced`
event, rather than falsely announcing the reflowed screen as new output. Parsed
OSC 133 prompt kinds and cell roles (`prompt`, `input`, and `output`) are
carried forward as immutable data; the model does not invent command boundaries
from them. Alternate-screen enter, exit, and repaint are represented explicitly
and never become shell history appends. Future UI and screen-reader code decides
how to navigate, coalesce, or speak these values.

## Accessible conversation and terminal presentation

Raw terminal geometry is an implementation detail. `TerminalPresentationModel`
is the user-facing layer above `TerminalAccessibilityModel`; it converts
semantic terminal updates into a small accessible conversation transcript. It
accepts only a narrow `TerminalPresentationSession` capability and has no
Citadel, NIO, SwiftTerm, or NVDA IPC dependency.

This is the first provider of FarRelay's shared Accessible Conversation
experience. SSH terminals, CLI agents, local models, OpenClaw, assistants, and
future conversational providers should supply semantic conversation events,
not separate accessibility implementations. This slice proves only the terminal
representation and does not introduce agent or provider dependencies.

Commands and responses have distinct semantic roles. A submitted command is
retained exactly as an outbound command entry while the same UTF-8 bytes and
Return byte continue through the existing terminal input path. Incoming output
uses the accessibility model's completed-line and current-line events, so a
streaming current line updates one entry instead of becoming byte-by-byte chat
noise. Blank physical viewport rows never become transcript entries, and
soft-wrapped logical output remains joined by the accessibility model.

SwiftUI supplies the normal accessibility behavior: command entries use native
heading semantics, output uses native selectable text, input remains a native
text-entry control, and buttons remain buttons. FarRelay does not recreate
VoiceOver's built-in heading, link, selection, or text-navigation features.
Custom Actions-rotor items are FarRelay-specific: `Copy`, `Run Again`, and
`Open Snapshot`. Native text selection remains.

Conversation means operate; a Snapshot means inspect. An incoming conversation
entry can be explicitly captured as an immutable `AccessibleConversationSnapshot`:
its exact accessible text and source-entry identifier are copied at capture time,
then presented through normal SwiftUI navigation as native selectable text.
The Snapshot never reads terminal bytes, refreshes from the terminal, or mutates
the live conversation, so output can be read without subsequent streaming or a
new terminal lifetime moving content under VoiceOver focus. The small Snapshot
value is provider-neutral and may later serve other conversation providers
without introducing those dependencies now.

When the terminal supplies OSC 133 roles already parsed by `TerminalEngine`,
the presentation layer groups consecutive `.output` lines into one incoming
response block, stores prompt-only lines as unobtrusive `shellPromptContext`
instead of conversation messages, and suppresses a shell command echo only
when `.input` semantics prove it matches the last FarRelay outbound command
text-for-text. It does not reparse ANSI/OSC in SwiftUI and does not invent
those boundaries when marks are absent. Without shell integration, the
previous per-completed-line fallback remains. Alternate-screen applications
stay an inspectable replacement display rather than fabricated append-only
history.

A response block that reaches 50 logical lines or 4,000 characters is still
stored in full on the conversation entry and in any Snapshot. The conversation
list presents a compact summary (`Large output, N lines. Open Snapshot.`),
Copy still copies the complete text, and live VoiceOver announcements become
`Large output received, N lines.` Focus is not moved. Search, rich link
metadata, onboarding, and productivity features such as Starred Commands and
a command palette remain future phases. Host Profiles and NVDA-as-a-host-capability
live at the app composition boundary. Multiple simultaneous terminals are owned
by `TerminalSessionManager`. Agents and Assistant remain honest empty shells
until those features are implemented.

The ownership boundary is intentionally strict:

```text
SSHTerminalSession
    owns coordination with the SSH PTY
TerminalEngine
    owns parsing and terminal state
TerminalAccessibilityModel
    owns semantic accessibility interpretation
TerminalPresentationModel / TerminalPresentationView
    own accessible conversation interaction and presentation
```

The SwiftUI surface does not poll terminal text, automatically move focus, or
announce every incoming character. `SSHTerminalSession` publishes immutable
snapshots and the presentation model consumes the existing semantic events.
Normal transcript navigation replaces the old explicit Review Terminal Content,
Previous Line, Next Line, and Return to Live controls. Presentation does not
infer geometry: a higher-level owner may explicitly request rows and columns
through the existing local-engine-then-remote-PTY resize path.

Live output informs without hijacking. `DynamicReadingQueue` is the shared,
provider-neutral queue for streaming announcements. It coalesces updates to
one logical entry, preserves FIFO order for unrelated entries, and cancels all
pending work when a session lifetime ends. Active terminal input does not
discard meaningful output; only Dynamic Reading being disabled, history
inspection, or Snapshot inspection suppresses delivery. UIKit delivery uses
the public VoiceOver announcement notification boundary and never moves focus.
Initial terminal history is seeded into the conversation but never queued.

SwiftUI is only the delivery and focus boundary. It observes VoiceOver focus
with `AccessibilityFocusState`, keeps the native terminal text field as the
owner of editing, and uses the VoiceOver environment value to avoid delivery
when VoiceOver is off. Output never takes responder or accessibility focus.
Leaving the terminal resigns the native responder and dismisses the software
keyboard while preserving typed text. Cursor movement, reflow, screen
replacement, and alternate-screen repaint do not become live announcements.
Focus ownership is explicit: `KeyboardCapture` owns first responder only for
the NVDA Remote raw-key surface; a terminal `TextField` owns it while editing;
Dynamic Reading is announcement-only and never becomes a focus target.

UIKit's public `UIKeyCommand` and `UIResponder` press APIs are used as the
strongest available Remote Control forwarding attempt. VoiceOver may consume
hardware arrows and Escape before an app responder receives them; public iOS
APIs provide no supported override for that case. Forwarding is never enabled
globally, and turning it off immediately restores normal local navigation.
Physical VoiceOver validation remains required.
Terminal Control Keys are a small, global data-driven collection rather than a
hardcoded presentation enum. Each `TerminalControlKey` owns a stable
terminal-scoped action ID, a user-editable label, and a semantic
`TerminalControlChord`; ordering is only collection order. The pure encoder
turns only supported chords into exact PTY bytes, and rejects ambiguous or
unsupported combinations rather than approximating them. The collection is
persisted as deterministic Codable data in `UserDefaults`: defaults are saved
only for a previously uninitialized configuration, while an intentionally
empty collection remains empty. Per-host Control Keys remain HostProfile work.

Future controller bindings may reference stable Control Key IDs without
depending on labels or order. Renaming or reordering therefore does not break a
binding; deleting a target will require that future adapter to handle a missing
ID gracefully. This phase does not include a controller adapter, GameController,
NVDA mapping, F11-style global remote input, or RemoteIntent expansion. OS- and
NVDA-level chords will later flow through their appropriate semantic targets
rather than being faked as PTY input.

## Interaction feedback

`InteractionFeedback` is a small app-level semantic player. Terminal and NVDA
models emit categories (`selectionAccepted`, `success`, `warning`, `error`,
`copied`) without knowing about vibration hardware or audio APIs. SwiftUI
`sensoryFeedback` delivers optional haptics from `RootView`. Short locally
generated WAV earcons use AudioServices UI sounds so they do not take the
shared audio session, duck VoiceOver, or interrupt `SpeechOutput`. They
respect the Silent switch.

Defaults migrate safely for existing installations: **Haptic feedback** is on,
**Sound cues** are off. The two toggles live under Settings → Interaction
Feedback and persist independently. Feedback is sparse: Send, Run Again,
Control Keys, Copy, Open Snapshot, pin/rename/move/close, terminal
connected/failed (delivered by `RootView` from manager lifecycle events), and
NVDA ready/failed. Incoming terminal lines, cursor motion,
VoiceOver focus moves, and New Output markers do not vibrate or play sounds.

## Terminal conversation actions and native input

The terminal should feel closer to an accessible messaging conversation than
to a visual grid. Command entries remain native headings. Incoming content
remains selectable text. The Actions rotor exposes `Copy` and `Run Again` on
commands, and `Copy` plus `Open Snapshot` on incoming output. The visible
Open Snapshot button remains. Output Snapshot also has `Copy All`. Copy uses
a tiny `AppClipboard` seam and posts `Copied` without moving VoiceOver focus.
Run Again still resends exact command bytes; a disconnected retry reports
error feedback and does not duplicate the command in the transcript.

Terminal input is a native `TextField` so VoiceOver Braille Screen Input can
type Unicode into it. Autocorrect and autocapitalization stay off. Send is an
explicit action (button, keyboard Send, or the `Send Command` rotor action).
Successful Send clears the field; failed Send preserves it. If the user was
already editing in the field, keyboard/editing focus is restored after a
successful Send so the next command can be typed immediately. VoiceOver
accessibility focus is observed, never stolen: live output must not yank the
user into the input, and remote output must not move local VoiceOver focus.
`Clear Input` is offered on the rotor only when the field has text.

## Accessibility interaction contract

Secondary actions that belong to a focused object are native SwiftUI
`.accessibilityAction(named:)` items on that object. FarRelay does not implement
a custom rotor, synthesize VoiceOver gestures, or plant invisible button farms.
Primary actions such as Add Computer, global New Terminal, Connect / Disconnect,
and Send remain visible. Object-specific work such as Pin, Rename, Close,
Retry, Move Up/Down, Run Again, Copy, Open Snapshot, Edit Computer, and Delete
Computer is not a row of extra buttons.

A terminal session row is one VoiceOver stop (`Claude, connected, pinned, new
output`). Its Actions expose only currently valid work. A Home computer row
exposes New Terminal, NVDA Remote when Windows and enabled, Edit Computer, and
Delete Computer. Delete confirms with a native alert and never kills captured
live terminals: those sessions keep running on their HostProfile snapshot, and
the saved computer is removed from Home.

Connection announcements (`Connecting to G14`, `Connected to G14`, `NVDA Remote
ready`, …) are informational `AccessibilityNotification.Announcement` posts.
They never move VoiceOver focus. Equivalent reconnect attempts are not
re-announced. Manual NVDA forwarding toggles announce on/off; automatic
`suspendInputForInactiveContext()` does not.

Final user-initiated failures present a native `UserFacingIssue` alert with
readable copy, optional Retry, Copy Details, and Dismiss. Copy Details is
redacted: no passwords, private keys, or `--channel` secrets. Missing remote
executables distinguish `farrelay` (NVDA bridge) from `farrelay-host` (host
protocol). Connecting, authenticating, automatic reconnect, stderr lines, and
in-shell command failures are not alerts.

## Accessibility polish non-goals

This phase does not implement controller adapters, GameController, F11-style
NVDA global remote mode, global hardware-keyboard passthrough, a Mac
RemoteIntent adapter, CGEvent/AXUIElement injection, custom BSI or braille
tables, Agents/Assistant runtimes, terminal persistence across app restart,
SSH multiplexing, command-history search, terminal tabs, or a visual redesign.

## Manual accessibility QA

Automated tests do not prove Braille Screen Input, haptics, or earcons on a
physical iPhone. Before claiming those surfaces are done, run:

### Braille Screen Input

1. Open an active terminal.
2. Focus Terminal input.
3. Enable Braille Screen Input.
4. Type a normal command.
5. Verify spaces and punctuation survive.
6. Send.
7. Verify the command is transmitted exactly once.
8. Verify the field clears.
9. Verify input remains usable for the next command.
10. Type another command immediately.
11. Verify incoming output does not steal input focus.
12. Test Unicode and accented text.
13. Test Clear Input.
14. Test a failed or disconnected send preserves typed text.
15. Leave BSI and inspect conversation Actions (Copy, Run Again, Open Snapshot).

### VoiceOver Actions, announcements, and alerts

- Terminals list: one stop per session; Pin / Unpin, Rename, Move Up/Down, Close, and Retry when applicable are Actions on that row, not extra buttons.
- Pinning sorts the session above unpinned sessions without reconnecting. Move Up never lifts an unpinned session over pinned sessions.
- Rename uses the compact alert, trims whitespace, and rejects an empty title.
- Home computer rows expose New Terminal, NVDA Remote when enabled, Edit, and Delete via Actions. Delete confirms and leaves active terminals running.
- Opening a terminal or creating a new one may move that computer group to the top. Background output must not.
- Connection announcements speak without moving focus. Final SSH/NVDA failures show a native alert with Retry when possible and Copy Details without secrets.
- NVDA forwarding announces only for the Toggle; leaving the screen must stay quiet.

### Haptics and sound cues

- Haptics on, sounds off: Send, Copy, and Run Again produce a tactile response; streaming terminal output does not vibrate repeatedly.
- Haptics off: the app does not generate haptics.
- Sound cues on: cues are brief and distinguish ordinary success from error; VoiceOver and FarRelay speech remain understandable; streaming output does not spam sounds.
- Sound cues off: silence.

## FarRelay app shell

The main tabs are exactly Home, Terminals, Agents, and Assistant. Settings is
a Home toolbar sheet, not a tab. There is no top-level NVDA tab.

Home is the saved-computer directory. Each `HostProfile` is one computer
(address, port, user, authentication, platform, and host-specific
capabilities). Credentials stay in the Keychain under a profile-scoped
reference; profile JSON may record authentication mode and credential
metadata but never passwords, private keys, or passphrases. A Tailscale IP,
MagicDNS name, LAN IP, or ordinary hostname is just an SSH address—the app
does not embed a VPN SDK or infer platform from the address.

`HostPlatform` (`windows`, `macOS`, `linux`, `other`) is descriptive and
capability-gating metadata. It does not change SSH semantics. Missing
legacy JSON decodes as `other`. Changing platform does not change the
profile ID.

NVDA Remote is an optional capability of a Windows `HostProfile`. Windows
does not imply that NVDA is configured. Non-Windows computers do not expose
or activate it. Navigation is Home → computer → NVDA Remote. Keyboard
capture exists only while that operating screen is active; leaving it, or
leaving the Home tab, suspends forwarding and releases held keys. The
bridge remains SSH-backed `farrelay --ipc`. The structured host command is
`farrelay-host` and must not be collapsed with that bridge command.

Agents is the future home of things the user directly operates (Claude Code,
Codex, local coding agents). Assistant is a future cross-host semantic
orchestrator. Both are empty states in this phase.

`TerminalSessionManager` is app-owned. It is the authoritative lifetime owner
for live terminals. Each `TerminalSession` has a stable UUID, a HostProfile ID,
a captured profile snapshot, a user-facing title, and its own `SSHTerminalHost`.
Default titles remain `Terminal 1`, `Terminal 2`, … scoped per host. Rename
changes only the display title. Identity is never the title.

Display order is not creation-array order. Within one computer group, pinned
sessions sort above unpinned sessions, and each category is newest-first unless
the user explicitly Move Up / Move Down. Pin, unpin, rename, and reorder never
reconnect and never change the session UUID. Passive terminal output and
connection status never reorder sessions or host groups. Creating a terminal,
retrying, or opening a session may promote that HostProfile group to the top
because those are explicit user actions.

Retry does not restart the failed `SSHTerminalHost` (one host object is one
terminal lifetime, and `start()` would wipe that transcript). The failed session
stays inspectable. A replacement `TerminalSession` is created with a new host
and the same user-facing title. Success is not claimed until that replacement
actually connects.

Unseen output is a boolean on the session. Output while that terminal is the
active presented interaction does not mark it. Output while another screen is
active does. Opening the terminal clears the marker; VoiceOver focus on the row
does not. Closing removes the session and the marker.

The manager exposes capabilities (`canPin`, `canRetry`, `canMoveUp`, …) and the
UI only surfaces currently valid VoiceOver Actions. It publishes typed terminal
lifecycle changes, but does not create alert copy or post accessibility
announcements. `RootView`, which owns app-level presentation and feedback,
maps those changes to concise announcements, semantic feedback delivery, and
final-failure `UserFacingIssue` alerts. SSH transport remains unaware of all
three presentation concerns.

That host still owns exactly one SSH connection, PTY, `SSHTerminalSession`, and
`TerminalPresentationModel`. The manager does not persist sessions across app
termination, and it does not keep sockets alive through iOS suspension beyond
existing SSH behavior.

Home owns saved computers. Terminals owns running and retained sessions,
grouped by HostProfile ID. Only computers with at least one retained session
appear there. Native `DisclosureGroup` expand/collapse is memory-only; new
host groups default to expanded, and incoming output does not force a group
open. Per-group and global **New Terminal** create another independent session
for a still-saved HostProfile. A deleted HostProfile cannot mint new terminals
from a stale group, but already-running sessions keep their snapshot identity
and are not silently terminated. Rename uses the current saved display name
when the profile still exists.

Back navigation, tab switching, Settings, and Output Snapshots do not close a
terminal. Only explicit Close Terminal, or manager cleanup, removes a session.
Failed and ended sessions remain inspectable until the user closes them.
Closing the last session for a host removes that group from Terminals; the
saved HostProfile remains on Home.

RemoteIntent terminal targeting is explicit and current-context based: intents
resolve against the currently presented `TerminalSession` only. If no terminal
is the active interaction context, terminal intents return unavailable rather
than operating a hidden session. Future controller bindings may target a
`TerminalSession` ID. They must not guess from titles or list positions.

Future Mac VoiceOver remote-control work, Agents, and Assistant remain after
this phase. The host now exposes a typed VoiceOver capability seam; iPhone
Remote Control UI, RemoteIntent-to-Mac mapping, and controller input are still
later slices. Future controller adapters also consume the stable terminal-scoped
Control Key IDs created with Terminal Control Keys, not labels or list
positions.

## App-level SSH terminal host

`SSHTerminalHost` remains the narrow composition owner for **one** interactive
terminal. `TerminalSessionManager` owns many of them. A host builds an
`SSHSessionConfiguration` from the HostProfile snapshot supplied at session
creation and that profile's Keychain credentials—the same profile-scoped
endpoint, authentication, credential, and host-key behavior used by the NVDA
bridge—then creates one `SSHSession`, opens one production `SSHPTYTransport`,
creates one `SSHTerminalSession`, and attaches that session to its own
`TerminalPresentationModel`. It does not use the reconnecting NVDA supervisor,
parse terminal bytes, share an NVDA IPC channel, or multiplex SSH connections.

```text
FarRelayApp
    TerminalSessionManager
        TerminalSession
            SSHTerminalHost
                SSHSession
                SSHPTYTransport
                SSHTerminalSession
                    TerminalEngine
                TerminalAccessibilityModel
                TerminalPresentationModel
```

Opening **New Terminal** from Home or the Terminals workspace asks the manager
to create a session. The presentation view never starts a second host and never
closes the host on disappearance. Close Terminal goes through the manager,
which closes only that host and removes only that session. NVDA Remote remains
a parallel host capability with independent state and lifetime.

## FarRelay Host v1

`FarRelayHostConnection` composes one connected `SSHSession` with exactly one
long-lived `farrelay-host` exec channel. `FarRelayHostClient` sits above the
generic byte-oriented `SSHExecTransport`: it owns version-1 NDJSON framing,
request-ID correlation, typed Codable results, structured errors, and bounded
stderr diagnostics. `SSHSession` remains unaware of the Host protocol. VoiceOver
operations are structured `farrelay-host` exec requests; they are not sent over
a PTY and do not use a second SSH connection system.

Mac remote control is conceptually one HostProfile capability, analogous to NVDA
Remote on Windows. This phase adds only the host/protocol seam and typed client
operations. It does not add a Remote Control screen, RemoteIntent mapping,
controller input, AXUIElement navigation, or CGEvent injection.

```text
FarRelay iPhone
    ↓
SSH exec
farrelay-host
    ↓
VoiceOverProvider
    ↓
macOS VoiceOver AppleScript bridge
```

VoiceOver remains the actual screen reader. FarRelay does not recreate VoiceOver
navigation. AXUIElement is a future fallback/verification layer. CGEvent is a
future raw-input fallback. Physical Mac validation is required before claiming
that real VoiceOver control works; GitHub-hosted macOS runners are not a
substitute.

```text
FarRelay Host v1                 ✓
Apple HostClient transport       ✓
macOS VoiceOver host operations  ✓ (protocol/client seam; physical proof pending)
HostTarget                       ✓
RemoteIntent capability router   ✓
Mac Remote executor              ✓ (existing lease-backed diagnostic actions only)
```

## Remote intent routing

Input adapters produce immutable, platform-neutral `RemoteIntent` values. A
`RemoteIntentRouter` owns registered semantic targets and routes each intent
only to the explicitly selected active target. It never automatically selects
a target and never falls through to another target when the active target is
unavailable or does not support an intent.

```text
Keyboard / controller / voice / local agent / ACP or OpenClaw adapter
    produces RemoteIntent
RemoteIntentRouter
    selects one explicit target
NVDARemoteIntentTarget                 TerminalRemoteIntentTarget
    calls BridgeClient.sendKey              calls TerminalPresentationModel
    owns no NVDA IPC                         owns no PTY or terminal parser
```

Targets advertise static capabilities separately from runtime readiness.
`NVDARemoteIntentTarget` can therefore support application navigation while
returning unavailable if BridgeClient forwarding is off or its input channel
is not ready. The terminal target can support terminal control while returning
unavailable until a terminal session is connected. Transcript navigation is
native SwiftUI and VoiceOver behavior rather than a RemoteIntent review mode.
The router returns a structured performed, unsupported, unavailable, or failed
result rather than falling back or relying on logs.

`HostTarget` is the inspectable target snapshot: stable target identity,
optional `HostProfile` and terminal-session identities, platform, target kind,
connection/readiness state, and static capabilities. It intentionally carries
no transport or controller reference. A `HostTargetExecutor` holds those
references and is the only layer allowed to adapt an intent to the existing
owner. The router records its last no-target, capability-rejection, or dispatch
decision so adapters can diagnose a result without probing another target.

The Mac executor wraps the existing `MacRemoteSession`; it neither connects a
host nor requests control. It exposes only the foundation's existing semantic
diagnostic actions (next/previous VoiceOver item, activate, and next
application). Execution requires the active controller lease and delegates HID
injection to `MacRemoteSession`. A rejected or failed key transition invokes
the existing remote emergency-stop operation instead of attempting another
transport. The diagnostic Mac controls select this target explicitly and route
through the shared router.

Keyboard, controller, voice, local-agent, ACP, and OpenClaw adapters are
independent consumers of this semantic layer. The existing keyboard capture,
NVDA IPC, SSH lifecycle, terminal parsing, and terminal accessibility layers
retain their current ownership.

## iOS controller adapter

`DualSenseControllerAdapter` is the current GameController consumer. It maps
the logical elements reported by iOS (including a user’s system controller
remapping) to FarRelay-owned `ControllerInput` identifiers, resolves only the
active versioned `ControllerProfile`, and emits `RemoteIntent` values through
the router. It never reaches `BridgeClient` or a host executor directly.

The controller mapping screen stays editable when no controller is paired, but
reports the runtime surface of the attached extended-gamepad profile. Optional
Options, Home, stick-click, and DualSense touchpad-press controls are only
reported available when GameController exposes them. Analog sticks use a 0.65
press / 0.45 release hysteresis pair to produce stable cardinal inputs.

Controller actions use explicit press, repeat, and release intents. The
adapter remembers both the chosen action and target identity at press time;
release therefore returns to the original target even if the active UI target
changes. Editing a mapping, controller disconnect, app inactivity, or adapter
teardown releases every action begun by the adapter. The NVDA target reference
counts held keys and modifiers, preserving shared modifier ownership across
overlapping chords. Bridge channel teardown remains the final `release_all`
safety boundary for transport loss.
