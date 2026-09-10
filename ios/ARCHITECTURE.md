# iOS connection architecture

## Before the SSH extraction

`BridgeClient` owned two different concerns:

- NVDA behavior: `nvdr --ipc` command construction, line-oriented IPC parsing,
  NVDA state mapping, speech forwarding, keyboard commands, forwarding state,
  and `releaseAll` on stop/disable.
- SSH transport: endpoint values, password/Ed25519/RSA authentication setup,
  custom RSA SHA-2 algorithm registration, Citadel connection lifecycle,
  exec-channel creation, and byte transport over stdin/stdout/stderr.

Authentication parsing and RSA/OpenSSH support lived beside the bridge driver,
which made the SSH path difficult to reuse for another remote host or protocol.

## After the SSH extraction

`BridgeClient` remains the NVDA-specific consumer. It creates the remote
`nvdr --ipc` command, maps settings into a plain `SSHSessionConfiguration`,
consumes generic SSH events as IPC text, and retains all forwarding and speech
semantics.

`SSHSession` owns generic SSH endpoint/authentication configuration, Citadel
connection and exec lifecycle, and a byte-oriented `SSHExecTransport`. The
transport exposes stdin writes and stdout/stderr events without exposing
Citadel or NIO types to `BridgeClient`.

The current host-key and reconnect behavior is intentionally preserved and
made explicit as `.acceptAnything` and `.never`. They are extension points for
future verification, pinning, keepalive, and reconnect policy work.

`SSHSession.authenticationSummary(for:)` is the synchronous, network-free
validation seam for authentication selection and key parsing. The repository
does not currently contain an iOS unit-test target; adding one would require
XcodeGen/Xcode project changes and test-only key fixtures, so this extraction
keeps the seam isolated without introducing an unverified test target.
