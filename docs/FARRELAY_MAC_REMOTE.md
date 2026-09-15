# FarRelay Mac Remote foundation

Status: semantic-speech provider packaging and local handoff implemented;
physical macOS validation is required before any remote-control feature is
called working.

## Principle

FarRelay transports the target screen reader's interpretation. It does not
create a second macOS screen reader or synchronize the accessibility tree.

```text
controller key event -> authenticated FarRelay session -> target FarRelay.app
  -> CGEvent -> macOS -> VoiceOver
  -> FarRelay Remote Voice -> app-group handoff -> FarRelay session
  -> controller-local synthesis
```

The input and feedback paths stay independent. A missing speech bridge cannot
change target keyboard injection, and an input disconnect cannot leave held
modifiers active.

## Semantic VoiceOver speech spike

`FarRelayRemoteVoice.appex` is a public
`AVSpeechSynthesisProviderAudioUnit` extension. Apple documents that speech
providers receive an `AVSpeechSynthesisProviderRequest`, including its final
SSML representation, and that voices supplied by these extensions are made
available to accessibility technologies including VoiceOver. The extension
advertises **FarRelay Remote Voice** and records only the public SSML request;
it does not invent a plain-text rendering, language, role, or state.

The extension intentionally renders silence. In this spike, selecting the
voice means the target can remain quiet while the controller renders the
target's VoiceOver output locally. It is not a claim that local VoiceOver audio
has been replicated or that all VoiceOver contexts have been physically proven.

The extension's `cancelSpeechRequest()` produces a `cancel` event. The
transport-neutral event model is:

```text
RemoteSpeechEvent {
  generation, sequence, kind (utterance | cancel | pause | resume),
  ssml?, plainText?, language?, timestamp
}
```

SSML is the authoritative provider field, because it is the only rich request
representation the public API exposes. The extension may also derive a
plain-text fallback by extracting character data from valid SSML; it never
adds role/state wording. Each extension process uses a new generation and
monotonically increasing sequence numbers. Payloads are bounded to 32 KiB.

### Extension-to-app boundary

Apple prohibits network access from speech synthesizers. The extension never
opens a listener and never contacts SSH, a relay, or the Internet. Instead it
uses a signed App Group, `group.com.sebb7.farrelay`, to write a bounded FIFO of
at most 64 short-lived events. It posts a content-free macOS distributed
notification; FarRelay.app drains the queue at launch and on that notification,
not by polling. Draining atomically clears the group file. Speech content is
therefore transient local handoff data, not history or diagnostics.

The app retains received events in a bounded in-memory FIFO for the future
same-user local proxy. That proxy is the only component intended to bridge an
authenticated SSH session to FarRelay.app. No LAN/WAN listener is permitted.

### Loop prevention

Remote controller speech must be produced with an ordinary local
`AVSpeechSynthesisVoice`, never with `FarRelay Remote Voice`. The provider is
only selected as the target's VoiceOver voice, so controller-local synthesis
does not re-enter the provider. The session layer must additionally reject
events whose generation is stale and clear its renderer/queues when a session
ends. This is an explicit routing rule, not a timing heuristic.

## Feedback fallback order

Capability discovery must make the active feedback mode visible:

1. **Remote VoiceOver output** — the semantic provider event path.
2. **Remote system audio** — only after explicit Screen Recording permission.
3. **Minimal feedback** — fixed VoiceOver AppleScript state and minimal AX
   context for diagnostics/resynchronization.

Apple's current ScreenCaptureKit documentation supports audio stream outputs,
`capturesAudio`, sample-rate/channel configuration, and
`excludesCurrentProcessAudio`. It still requires Screen Recording permission
and may include app/notification audio in addition to VoiceOver. Until a real
Mac proves otherwise, FarRelay must describe this fallback as **system audio**,
not VoiceOver-only audio. No screen video is part of this foundation.

The earlier fixed AppleScript VoiceOver operations remain useful only for
limited diagnostics, resynchronization, and degraded state. They are not the
primary narration path and must always remain fixed application-owned scripts.

## Input and control safety

The foundation now defines stable USB-HID-style `RemoteKey` values, key
down/up, a single-controller lease, generation checks, and deterministic
release-all policy. `MacRemoteInputEngine` posts public `CGEvent`s only after
Accessibility permission is present. It tags FarRelay-originated events with
supported event-source user data; controller-side `KeyCapture` ignores that
marker. The existing local forwarding toggle remains the emergency stop and
must release all held target keys as the session transport is connected.

Only one controller may own target keyboard input in P0. Observers and a full
AX tree are explicitly out of scope.

## Physical tester sequence

This is a development spike, not a signed/notarized tester build. On a test
Mac with the matching App Group entitlement:

1. Build the `FarRelay` scheme; it embeds `FarRelayRemoteVoice.appex`.
2. Launch FarRelay once so macOS registers the extension, then wait for the
   system voice list to refresh.
3. In VoiceOver voice settings, select **FarRelay Remote Voice**. Record the
   original voice first so it can be restored.
4. Start VoiceOver and navigate Finder, Safari, System Settings, menus,
   tables, text fields, buttons, checkboxes, and selected items.
5. Verify FarRelay's provider panel increments its semantic-event count
   without displaying phrase content in logs.
6. Exercise rapid VO-Right/VO-Left and interruption. Verify event ordering,
   cancellation, and that the bounded queue does not retain stale output.
7. Restore the original VoiceOver voice. Do not send SSH keys, passwords,
   channels, raw speech contents, or audio recordings in diagnostics.

Required evidence before declaring success: whether VoiceOver actually selects
the voice; semantic request completeness; cancellation behavior; ordering;
SSML validity; measured end-to-end controller latency; and behavior while a
Mac is both controller and target.

## Non-goals in this foundation

No AX-tree synchronization, screen video, arbitrary scripting, listener or
daemon, FileVault/loginwindow control, clipboard/file transfer, braille
virtualization, or production release is included.
