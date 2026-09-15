# Physical regression checklist

Run this on representative iPhone/iPad, Mac, Windows/NVDA, and SSH target
hardware before calling a build physically validated.

## Connection

- [ ] Connect to an online target; confirm Connected appears only after authentication/session readiness.
- [ ] Press Connect while the target is powered off; confirm Connecting then a truthful failure and a Connect retry control.
- [ ] Shut down and reboot the target while connected; confirm no stale Connected state and no uncontrolled retry loop.
- [ ] Drop and restore Wi-Fi; verify explicit Disconnect cancels reconnect.

## Terminal

- [ ] Run a normal command and browse its transcript.
- [ ] Shut down the target from the terminal; verify the terminal becomes Ended/Failed and transcript remains readable.
- [ ] Simulate a network drop during a command.
- [ ] Open two terminals to one computer; end one and verify the other is unaffected.
- [ ] Close a terminal locally and retry an ended/failed terminal; verify the replacement gets a new identity.

## Keyboard and NVDA Remote

- [ ] F1, F2, F3, F5, F10, F11, F12 reach Windows/NVDA as those logical keys.
- [ ] Control+F1, Shift+F10, and Alt+F1 preserve the entire chord and release modifiers.
- [ ] Verify arrows, Tab/Shift+Tab, Escape, Enter, Backspace, Delete, Home, End, Page Up, and Page Down.
- [ ] Test with VoiceOver/TalkBack on and off, and with macOS function keys configured as media controls.
- [ ] Toggle forwarding and disconnect while holding Control, Alt, Shift, and Caps Lock; verify nothing remains held remotely.
- [ ] Confirm waiting-for-NVDA is not announced or presented as slave-ready.

## Mac Remote foundation

- [ ] Verify permission-degraded, input-ready, and feedback-ready states separately.
- [ ] Verify Emergency Stop releases remote input.
- [ ] Mark all Remote Voice/provider claims unvalidated unless exercised on physical macOS hardware.
