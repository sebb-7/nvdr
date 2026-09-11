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

## Terminal presentation

`TerminalPresentationModel` is the user-facing layer above
`TerminalAccessibilityModel`. It owns live versus review mode, a selected
review line, session-state labels, byte-exact text submission, and the small
set of explicit terminal key actions exposed by the first SwiftUI terminal
surface. It accepts only a narrow `TerminalPresentationSession` capability;
it has no Citadel, NIO, SwiftTerm, or NVDA IPC dependency.

The ownership boundary is intentionally strict:

```text
SSHTerminalSession
    owns coordination with the SSH PTY
TerminalEngine
    owns parsing and terminal state
TerminalAccessibilityModel
    owns semantic accessibility interpretation
TerminalPresentationModel / TerminalPresentationView
    own user-facing navigation and presentation
```

Live mode follows the current logical terminal line as snapshots arrive. Review
mode retains the user-selected logical line, so appended output never forces a
VoiceOver user back to the cursor. Returning to live mode explicitly resumes
following the current line. The SwiftUI surface exposes logical lines as native
accessibility elements rather than terminal cells, identifies the current and
reviewed line in its labels, and does not automatically announce or move focus
for every incoming character.

Alternate-screen snapshots replace the currently presented terminal content;
they are never presented as appended shell history. Presentation does not infer
geometry: a higher-level owner may explicitly request rows and columns through
the existing local-engine-then-remote-PTY resize path.

## App-level SSH terminal host

`SSHTerminalHost` is the narrow app-level composition owner for one interactive
terminal. It reuses `AppSettings.sshSessionConfiguration()`—the same endpoint,
authentication, credential, and host-key behavior used by the NVDA bridge—to
create one `SSHSession`, open one production `SSHPTYTransport`, create one
`SSHTerminalSession`, and attach that session to `TerminalPresentationModel`.
It does not use the reconnecting NVDA supervisor, parse terminal bytes, or
share the NVDA IPC channel.

```text
App / SSHTerminalHost
    owns composition and feature lifetime
SSHSession
    owns SSH connection lifecycle
SSHPTYTransport
    owns byte-oriented PTY transport
SSHTerminalSession
    owns PTY reader coordination and TerminalEngine
TerminalAccessibilityModel
    owns semantic interpretation
TerminalPresentationModel / TerminalPresentationView
    own accessible interaction
```

Opening **Open SSH terminal** creates this independent terminal feature from
the saved SSH settings. The host reports connecting, startup failure, end, and
close through the presentation model. Closing the view first closes the
terminal session, cancels host work, and then releases the SSH connection;
repeated closes are safe. NVDA IPC remains a parallel feature with independent
state and lifetime.

## FarRelay Host v1

`FarRelayHostConnection` composes one connected `SSHSession` with exactly one
long-lived `farrelay-host` exec channel. `FarRelayHostClient` sits above the
generic byte-oriented `SSHExecTransport`: it owns version-1 NDJSON framing,
request-ID correlation, typed Codable results, structured errors, and bounded
stderr diagnostics. `SSHSession` remains unaware of the Host protocol and no
Host client is connected to UI, terminal, NVDA, or remote-intent routing.

```text
FarRelay Host v1                 ✓
Apple HostClient transport       ✓
HostTarget                       NEXT
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
is not ready. The terminal target can support review/control while returning
unavailable until a terminal session is connected. The router returns a
structured performed, unsupported, unavailable, or failed result rather than
falling back or relying on logs.

Keyboard, controller, voice, local-agent, ACP, and OpenClaw adapters are
future consumers of this semantic layer. They are not implemented here, and
the existing keyboard capture, NVDA IPC, SSH lifecycle, terminal parsing, and
terminal accessibility layers retain their current ownership.
