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

`BridgeClient` creates a new `nvdr --ipc` exec channel for every connected
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

The `nvdr --ipc` protocol has a meaningful clean end: `state quit` follows a
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
