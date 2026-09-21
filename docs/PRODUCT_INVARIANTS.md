# FarRelay product invariants

This is the living, testable engineering contract for FarRelay. Status means
the current implementation evidence, not product intent. A reproducible bug in
state, protocol, input, accessibility, or data safety gets a permanent
regression test unless the exception and the physical-only reason are recorded.

## Connectivity

| ID | Status | Contract |
| --- | --- | --- |
| CONNECTION-001 | Enforced | A computer is shown as **Connected** only after its required authenticated transport is usable. A connect request is never itself a connection. |
| CONNECTION-002 | Enforced | `Connect` moves through Connecting/Authenticating; failure ends in Failed or Disconnected with an accessible reason. The control offers Cancel while pending, not Disconnect. |
| CONNECTION-003 | Partially enforced | Explicit Disconnect invalidates the current generation, cancels reconnect, closes the active transport, and prevents late callbacks from making it connected. |
| CONNECTION-004 | Partially enforced | Reconnecting is never presented as Connected, and a stale connection generation cannot change a replacement connection's state. |
| CONNECTION-005 | Not yet enforced | Errors are classified as host unreachable, refused, authentication failed, host identity changed, connection lost, or remote session ended whenever the transport exposes the distinction. |

## SSH and terminal lifecycle

| ID | Status | Contract |
| --- | --- | --- |
| SSH-001 | Enforced | Host-key validation is TOFU by default; a changed identity fails closed and secrets are not persisted in profile data. |
| TERMINAL-001 | Enforced | Each terminal owns one SSH connection, one PTY, one `SSHTerminalSession`, and one presentation model. Terminals do not share a computer transport. |
| TERMINAL-002 | Enforced | PTY EOF moves its terminal from Connected to Ended promptly, preserves received scrollback, and leaves it inspectable. |
| TERMINAL-003 | Enforced | PTY read/write/resize failure moves its terminal from Connected to Failed; explicit local close moves it to Closed. |
| TERMINAL-004 | Enforced | Retry creates a replacement terminal identity and host; old callbacks cannot update it and the old transcript remains inspectable. |

## NVDA Remote

| ID | Status | Contract |
| --- | --- | --- |
| NVDA-001 | Enforced in automated relay-state scope | NVDA forwarding is available only when the SSH-backed IPC channel is ready and a live slave is present; relay connection alone is not slave readiness. Modern and legacy peer-leave identifiers must retire the slave instead of leaving a ghost Ready state. |
| NVDA-002 | Enforced | A connection loss, channel replacement, screen exit, forwarding disable, or background transition releases remote keys and clears local held-key state. |
| NVDA-003 | Partially enforced | Relay disconnect and intentional remote quit are distinguishable from a ready slave; reconnect never queues keyboard input for a later channel. |

## Keyboard and input

| ID | Status | Contract |
| --- | --- | --- |
| INPUT-001 | Enforced | Every supported input emits balanced logical Windows key-down/key-up transitions, or is explicitly unsupported. |
| INPUT-002 | Enforced | F1-F12 map to Windows VK `0x70...0x7B`; F13-F24 remain on the raw-HID path where the platform exposes them. |
| INPUT-003 | Partially enforced | iOS priority key commands cover F1-F12 and modifier chords; matching raw events are deduplicated without timing heuristics. |
| INPUT-004 | Partially enforced | macOS function-row F1-F12 use the USB HID fallback because the OS can consume hardware-control keys before CGEvent delivery. |
| INPUT-005 | Enforced | A disconnect, session replacement, controller loss, or disabled forwarding must release every remotely held key/modifier. |
| INPUT-006 | Partially enforced | Left/right modifiers are preserved on raw platform paths; priority-command fallbacks use an explicitly documented left-side logical mapping. |
| INPUT-007 | Enforced in automated model/target scope | Controller mappings use typed press/repeat/release transitions; remapping, controller loss, inactivity, and adapter teardown release the original target’s held action. Physical DualSense and Windows/NVDA confirmation remains required. |

## App, host, diagnostics, and security

| ID | Status | Contract |
| --- | --- | --- |
| LIFECYCLE-001 | Partially enforced | Backgrounding suspends forwarding and releases held remote input; suspended sockets are not claimed alive without a later real transport event. |
| ACCESSIBILITY-001 | Enforced | Connection status has a truthful text label and transitions can produce concise VoiceOver announcements without focus theft. |
| DIAGNOSTICS-001 | Partially enforced | User-facing diagnostics use sanitized endpoint/status metadata and never include passwords, private keys, passphrases, channels, ordinary typing, or speech content. |
| MAC-REMOTE-001 | Not yet enforced | Mac Remote readiness is component-specific; no physical remote-control claim is made until hardware and permission validation passes. |
| RECOVERY-001 | Enforced | Windows accessibility recovery is independent of the NVDA relay. Status comes only from an authenticated SSH + `farrelay-host` response; relay state is never used as recovery health. |
| RECOVERY-002 | Enforced | Recovery executes the saved profile's host command. Empty commands and commands containing line breaks/NUL fail closed rather than silently falling back to a different executable. |
| RECOVERY-003 | Enforced | Remote NVDA restart can invoke only the fixed `FarRelay Recover NVDA` scheduled task; the remote request cannot choose an executable, task name, script, or arguments. |
| DISTRIBUTION-001 | Enforced in installer/readiness scope | The managed Windows installer places its FarRelay directory first in machine PATH, and the travel-readiness check rejects ambiguous or version-mismatched PATH-visible FarRelay binaries. |

## iOS lifecycle, protocol, persistence, and ownership

| ID | Status | Contract |
| --- | --- | --- |
| IOS-LIFECYCLE-001 | Enforced | Background/inactive transitions immediately revoke NVDA keyboard forwarding and issue `release_all`; foregrounding alone never creates a replacement connection. |
| IOS-GENERATION-001 | Enforced | A stale SSH or IPC callback may update state only when its supervisor and generation are still authoritative. |
| IOS-RECOVERY-001 | Partially enforced | Local control remains recoverable after screen exit, backgrounding, or connection loss; physical lock/unlock behavior requires device validation. |
| PROTOCOL-001 | Enforced | Unknown IPC lines are inert and malformed host responses fail the request deterministically without crashing later requests. |
| PROTOCOL-002 | Partially enforced | Structured host version mismatch rejects safely; optional host operations are discovered through advertised capabilities before use. |
| PERSISTENCE-001 | Enforced | A malformed saved-profile record does not crash startup or get overwritten with an empty record; it remains available for recovery. |
| PERSISTENCE-002 | Partially enforced | Legacy profiles retain missing-field defaults and credentials remain Keychain-only. |
| OWNERSHIP-001 | Not yet enforced | Future multi-controller features must establish one explicit input-controller owner; current NVDA relay input has no lease protocol. |
| DIAGNOSTICS-002 | Enforced | Test secret fixtures for passwords, keys, channels, and typed content must never appear in normal diagnostic output. |
| STATUS-001 | Partially enforced | Home derives connection, NVDA, terminal, and controller text from current runtime state; it never labels a connect request as Connected. Physical multi-target validation remains required. |
| CAPABILITY-001 | Partially enforced | Capability snapshots use extensible identifiers. Unknown optional capabilities are inert; a protocol-major mismatch fails closed. Current legacy NVDA IPC has no capability handshake. |
| OWNERSHIP-002 | Partially enforced | Controller lease state includes identity and generation gating. A lost/released lease rejects stale input locally; legacy NVDA IPC is explicitly unleased and must not be described as controller-owned. |
| EVENT-001 | Enforced | Important in-app events are typed, bounded, safe-copy only, and coalesced by deterministic keys. A repeated critical event does not repeatedly announce. |
| EVENT-002 | Enforced | Critical-event summaries, details, and copied status reports exclude credentials, relay channels, typed content, terminal transcripts, and speech content. |
| PERSISTENCE-003 | Enforced | Saved profile records carry an explicit schema version. Legacy profile bytes migrate deterministically only after the original bytes are retained for recovery. |
| PERSISTENCE-004 | Enforced | Malformed or newer unsupported profile schemas remain untouched; FarRelay presents recovery state instead of replacing them with an empty store. |

## Bug-to-regression policy

For each reproducible product bug, record the violated invariant, create the
narrowest deterministic reproducer, make it fail before the fix where
practical, and keep it in the normal CI suite. A physical-only case must name
the hardware dependency and remain in `PHYSICAL_REGRESSION_CHECKLIST.md`.
