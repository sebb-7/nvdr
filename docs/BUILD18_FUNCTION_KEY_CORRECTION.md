# Build 18 Function-Key Correction

## Boundary and evidence

Build 17 restored the saved-computer, terminal, and NVDA-status interface,
but physical testing showed no F1--F12 HID or `UIKeyCommand` delivery. That
locates the observed failure before the bridge, SSH transport, Windows
injection, and NVDA. Build 18 changes only the iOS input-delivery boundary.

This document distinguishes implementation and automated evidence from
physical delivery. Simulator and CI tests cannot prove a specific iPhone or
iPad keyboard, VoiceOver, Windows, or NVDA receives a chord.

## Capture and modifier policy

Native UIKit raw presses, priority `UIKeyCommand`, and additive `GCKeyboard`
capture remain available for F1--F12. `GCKeyboard` installs and removes its
handler with keyboard connection lifecycle, and releases logically-held
function keys at disconnect.

The remote contract is fixed on the active remote surface:

| Apple key | Remote Windows key |
| --- | --- |
| Option | Alt |
| Command | Windows |
| Control | Control |
| Shift | Shift |
| Caps Lock | Caps Lock |

Command is normally the Windows key. It is consumed only for the twelve
reserved fallbacks: Command+1 through Command+9 map to F1 through F9,
Command+0 maps to F10, Command+- maps to F11, and Command+= maps to F12.
The Command key and source key are never transmitted for a recognised
fallback. Other physically-held modifiers remain physically owned; missing
modifiers are balanced around the synthesized F-key tap.

Command is briefly buffered solely to distinguish those twelve combinations.
Option, Control, Shift, and Caps Lock are not globally intercepted. Therefore
Command+A and Command+R continue as Windows+A and Windows+R. Option+Command+4
is Alt+F4; Caps Lock+Command+4 is NVDA+F4 where NVDA uses Caps Lock; and
Caps Lock+Option+Command+4 is NVDA+Alt+F4.

VoiceOver may consume Caps Lock when it is configured as the local VoiceOver
modifier. The recommended NVDA-oriented configuration is local VoiceOver
Control+Option and remote NVDA Caps Lock. Physical testing must record what
iOS delivers with each local VoiceOver configuration.

## Deduplication and tests

`FunctionKeyDuplicateGate` identifies a candidate by Windows virtual key,
direction, modifier state, source HID usage, source path, and short-lived
delivery time. It suppresses only a matching event from a different capture
path. Same-source repeats, key-up events, changed modifiers, different keys,
and a later physical action remain eligible.

`FunctionKeyTransmissionPlan` is the single fallback sequencing authority.
`BridgeClient.forwardFunctionKeyTap` executes that plan directly; regression
tests assert the emitted order for plain, Alt, Control, Shift, and Caps Lock
fallbacks, including already-held modifier ownership. There is no separate
test-only fallback transition implementation.

## Diagnostics and provenance

Diagnostics identify raw UIKit, priority command, `GCKeyboard`, and Command
fallback provenance without recording typed text. A queued event is described
as queued for transport write with host receipt unconfirmed. The TestFlight
workflow writes the Git short SHA into the archive plist before signing, so a
new distribution build should report an embedded source revision rather than
`not embedded`.

## Validation record

The branch's previous CI success was run 35303266557 for
`49be2c61bb6ab8c520f20c8dc3453cb82359af36`. The corrected commit, branch CI,
exact-main CI, and TestFlight results are recorded after the correction is
validated. Physical function-key success remains unclaimed until tested on a
real iPhone or iPad, physical keyboard, Windows host, and NVDA.
