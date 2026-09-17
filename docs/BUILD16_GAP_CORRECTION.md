# Build 16 expectation-gap correction

## Scope and source evidence

Build 16 was uploaded by TestFlight run `35213987524` from main commit
`004e2c68a5080767889752890b9d8119932f77e6`. The workflow completed archive,
signing, export, and App Store Connect upload successfully. The physical
report that saved-computer status was absent and function keys did not reach
NVDA is therefore treated as authoritative product evidence.

The richer status/event foundation was preserved at
`ffdd3af86a850e1ef7534c64ab135683f35334ac` on
`codex/product-reliability-phase3-foundation`; it was not merged into Build
16. This correction ports only the small runtime status derivation needed for
the iOS saved-computer list. It does not port that branch's persistence schema,
migration, capabilities, or controller-lease work.

## Build 16 diagnosis

### Saved-computer/status interface

Build 16's Home screen rendered saved profiles as plain navigation rows: name,
platform, user, address, and port. It did not derive or show a per-computer
FarRelay/NVDA state, terminal count, failure reason, or connection action.

The connection-state work that reached Build 16 was limited to
`NVDARemoteFeatureView`, the detail screen opened after selecting a computer.
It correctly changed that screen's action label between Connect, Cancel
connection, and Disconnect, but did not add the expected saved-computer
status interface. A profile was consequently still visible as a profile, not
as a truthful status row.

### Physical F-key forwarding

Commit `8d644437f4b652ca14a178881eaabc0eb5fe6440` changed only
`RemoteInputMappingTests.swift`. It verifies that the HID F1–F12 and F13–F24
ranges map to consecutive Windows virtual-key values. It does not exercise a
UIKit responder, physical keyboard delivery, VoiceOver interception,
`BridgeClient` admission, SSH transmission, host receipt, Windows injection,
or NVDA behavior.

Code inspection identified two concrete client-side capture weaknesses in
Build 16:

1. The capture view was mounted as a zero-height SwiftUI overlay. Its first
   responder ownership was requested but not made observable or recoverable.
2. UIKit key-command registrations were conditional on forwarding state, but
   the capture view remained mounted across that state change. A fallback
   registration could therefore remain absent after a reconnect or a return
   to the screen.

The correction mounts a real, non-interactive 1×1 responder view, requests and
records responder activation while diagnostic mode is on, and recreates the
capture responder when forwarding changes so UIKit evaluates a fresh public
`keyCommands` surface.
This is a code-level correction for an unproven client boundary, not a claim
that iOS or VoiceOver will yield every function key.

## Validation boundaries

| Boundary | Current evidence |
| --- | --- |
| HID/F-key mapping and chord construction | Automated unit tests |
| UIKit raw press delivery / priority command delivery | Requires physical iPhone test |
| Bridge admission and queuing | Recorded by opt-in client diagnostics; automated unit tests cover mapping/state seams |
| SSH transmission and host receipt | Requires a connected host test; client report says only whether it queued |
| Windows injection | Requires Windows host confirmation |
| NVDA command behavior | Requires Windows/NVDA confirmation |
| VoiceOver interception and announcements | Requires physical VoiceOver test |

## Corrective implementation

* `FarRelayComputerStatus` derives one status per saved profile. Only the
  bridge's active profile receives remote-control state; other profiles remain
  disconnected even while another computer is active.
* Home rows announce computer name, connection state, NVDA state, terminal
  count, and an actionable reason. Their native action is Connect while idle
  or failed, Cancel connection while connecting/authenticating/reconnecting,
  and Disconnect only after an established relay/NVDA session.
* `InputDiagnosticStore` is explicitly opt-in, bounded to 50 technical
  records, and supports Copy and Clear. It stores source path, HID usage,
  modifiers, down/up, mapped virtual key, bridge result, app version, build,
  source revision, and connection state. It intentionally never stores typed
  text, credentials, terminal content, speech, or relay channels.
* TestFlight embeds the source revision in the app so diagnostic reports can
  identify the uploaded source state.

## Physical validation required after upload

1. Open NVDA Remote, enable **Record remote keyboard diagnostics**, and copy
   the report. Confirm app version, TestFlight build, and source revision.
2. On Home, verify every saved computer is announced with its own current
   status; connect one computer and confirm other rows remain disconnected.
3. Verify Connect, Cancel connection, and Disconnect at the matching states;
   verify a readable failure reason and distinct Waiting for NVDA state.
4. With VoiceOver off, test F1, F2, F3, F5, F10, F11, F12, Control+F1,
   Shift+F10, and Option+F1. Repeat supported F13–F24 keys if the hardware
   exposes them.
5. Repeat with VoiceOver on. After a failure, copy the report and record
   whether it shows raw press, key command, mapping, and queued transmission.
6. On Windows, confirm host receipt, Windows injection, and the resulting
   NVDA command. Test disconnect while a modifier is held, reconnect, host
   unavailable, and NVDA unavailable.

CI and TestFlight run details for the corrected main SHA are recorded after
the corrective branch is merged and validated.
