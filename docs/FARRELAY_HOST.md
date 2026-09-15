# `farrelay-host`

`farrelay-host` is an independent target-side executable for Windows, macOS, and Linux. It exposes a platform-neutral, versioned structured capability protocol over newline-delimited JSON (NDJSON): requests arrive on stdin and responses leave on stdout. Operational diagnostics belong on stderr. The intended transport is an authenticated SSH exec channel; the host does not open a separate network listener, become a daemon, or start a VoiceOver socket server.

It is an application, not a reusable library, so its `Cargo.lock` is committed
to keep deployed and CI dependency resolution reproducible. Dependency updates
remain deliberate changes rather than part of protocol work.

## Bundled Mac proxy

In FarRelay Mac Beta 0.1, the executable embedded at
`FarRelay.app/Contents/Helpers/farrelay-host` also accepts `--proxy`. The
installed app starts a private Unix-domain socket at the deterministic,
same-user path `~/Library/Application Support/FarRelay/farrelay-host.sock`
only while **Allow remote control of this Mac** is enabled. The socket
directory is mode `0700`, the endpoint is mode `0600`, and the app verifies
the connecting peer's uid where macOS supports it.

The proxy forwards bounded (32 KiB) NDJSON between the authenticated SSH exec
channel and that socket. It has no TCC ownership, no daemon role, no TCP/UDP
listener, no discovery advertisement, and no durable speech storage. If the
app is stopped or the endpoint is stale, the proxy fails closed. The native app
continues to own permission checks, controller leases, held-key release, and
CGEvent injection.

The v1 host always supports `host.info`, `process.list`, and `process.info`. On macOS it also advertises VoiceOver operations. It has no arbitrary shell execution, arbitrary AppleScript execution, command runner, daemon installation, or service lifecycle API. It remains separate from the existing NVDA Remote relay/client responsibilities.

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

On Windows and Linux the VoiceOver provider is present only as an unsupported-platform implementation. Those hosts continue to advertise `host.info`, `process.list`, and `process.info` only.

## Operations

Protocol version remains **1**. Optional operations do not bump the version.

| Operation | Platforms | Notes |
| --- | --- | --- |
| `capabilities` | all | Static implementation support. macOS includes VoiceOver operations; Windows/Linux do not. Advertisement does **not** mean VoiceOver is running. |
| `host.info` | all | OS family, version, architecture, hostname, implementation. |
| `process.list` | all | Snapshot of processes. |
| `process.info` | all | One process by pid; `process_not_found` when missing. |
| `voiceover.status` | macOS | Runtime probe: platform support, availability, best-effort running flag, AppleScript-bridge usability. |
| `voiceover.move` | macOS | Strict direction enum: `left`, `right`, `up`, `down`, `into`, `out`. |
| `voiceover.press` | macOS | Activate the current VoiceOver item through the scripting bridge. |
| `voiceover.state` | macOS | Optional `last_spoken_phrase`, `voiceover_cursor_text`, `keyboard_cursor_text`. |

macOS capability advertisement means: **this host implementation supports these operations**. Runtime VoiceOver readiness belongs in `voiceover.status` and operation results.

Unknown `voiceover.move` directions return `invalid_parameters`. On Windows/Linux, VoiceOver operations return `unsupported_platform`. If VoiceOver does not appear to be running, operations return `voiceover_unavailable`. If the AppleScript bridge is not usable, they return `voiceover_control_unavailable`. CI must not treat compilation or mocked provider tests as proof of real VoiceOver control.

AppleScript is executed only as fixed `/usr/bin/osascript -e` templates. Request parameters never become AppleScript source. There is no `perform command "<anything>"` API in this phase.

AXUIElement, CGEvent injection, RemoteIntent mapping, and the iPhone Remote Control UI are deferred.

Run it through SSH with `ssh target farrelay-host`. The existing relay bridge continues to use `ssh target farrelay --ipc`; these are separate paths and the structured host protocol has not replaced the relay protocol.
