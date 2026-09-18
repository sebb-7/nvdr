# Build 18 Function-Key Correction

## Evidence and boundary

Build 17 was uploaded from `e5cdf6c1d4b3f4c1b281154de589eaf54627715c`
by [TestFlight run 35279214895](https://github.com/sebb-7/nvdr/actions/runs/35279214895)
(workflow run number 17, successful). Physical testing confirmed that Build
17 restored the saved-computer, terminal, and NVDA-status interface.

The same physical report proved the following:

* NVDA was connected and the keyboard capture view remained first responder.
* Ordinary keys, Tab (HID 43), Control (224), Shift (225), and Command (227)
  reached the UIKit diagnostic path and ordinary mapped keys were queued.
* Neither F1–F12 HID usages 58–69 nor an F-key `UIKeyCommand` callback
  appeared, including with Fn and Fn-lock combinations.

This proves the observed failure is before the bridge, SSH transport, host,
Windows injection, and NVDA. Build 18 therefore changes the iOS
input-delivery boundary only. It does not redesign Rust, host injection, or
NVDA behavior.

## Implemented capture paths

1. `GameControllerKeyboardCapture` observes `GCKeyboard` connection and
   disconnection and installs `GCKeyboardInput.keyChangedHandler` for F1–F12
   only. It forwards key down/up, observes Control/Option/Shift through the
   GameController keyboard profile, removes handlers during teardown, and
   releases logically pressed F-keys if a keyboard disconnects.
2. UIKit raw presses and `UIKeyCommand` remain in place as independent paths.
   A 75 ms, cross-source transition gate suppresses only duplicate delivery
   from a different API. It does not suppress same-source repeated physical
   input. Command-fallback duplicate deliveries are similarly coalesced only
   in that narrow window.

Simulator tests verify mappings and lifecycle policy; they do **not** prove a
physical keyboard will deliver `GCKeyboard` F-row callbacks.

## Direct Command fallback

The fallback is immediate and stateless:

| Local chord | Remote key |
| --- | --- |
| Command+1 … Command+9 | F1 … F9 |
| Command+0 | F10 |
| Command+- | F11 |
| Command+= | F12 |

Command is reserved as a local FarRelay transport modifier while the NVDA
Remote keyboard surface is active. It is never forwarded as Windows. For a
recognised fallback, both Command and the source number-row key are consumed;
only Control, Option/Alt, and Shift are preserved. Missing modifiers are
synthesised before the F-key and released after it; modifiers already owned by
the raw path remain physically owned and are not released by the fallback.

Control/Option/Shift are briefly held locally until the next non-modifier key
classifies the chord. This makes modifier press order irrelevant: a recognised
fallback synthesises the exact modifier/F-key tap, while another key flushes
the pending modifiers first and continues through normal remote input.

The explicit product tradeoff is that Command is no longer a Windows-key
shortcut on this active NVDA keyboard surface. An unrecognised Command chord
forwards its non-Command key after normal modifier classification, but never
leaks Command/Windows. This is required to make recognised fallback chords
deterministic.

## Diagnostics and provenance

The opt-in, bounded diagnostic report now identifies raw UIKit, `UIKeyCommand`,
`GCKeyboard`, and Command-fallback events; local consumption, deduplication,
keyboard connection/disconnection, responder status, modifier preservation,
and forwarding rejection reasons. It continues to exclude typed text,
credentials, terminal content, passwords, and speech.

The report now says `queued for transport write; host receipt unconfirmed`.
The existing NVDA relay protocol has no per-key host acknowledgement, so Build
18 deliberately does not overstate queued data as host-received. The
TestFlight workflow writes the short Git revision directly into the ephemeral
archive plist before signing, in addition to the Xcode build setting, to avoid
the Build 17 `Source revision: not embedded` result.

## Validation record

The remaining sections are filled after the Build 18 branch CI, exact-main CI,
and TestFlight workflow complete. Physical function-key success is not claimed
by source inspection or simulator coverage.

