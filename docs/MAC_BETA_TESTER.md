# FarRelay Mac Beta tester guide

1. Download `FarRelay.dmg`.
2. Open `FarRelay.dmg`.
3. Copy **FarRelay** to **Applications**.
4. Open FarRelay from Applications.
5. Complete the FarRelay setup assistant.

You do not need Terminal, Xcode, Git, Cargo, Homebrew, or a developer account.

## Setup

Open **This Mac**, enable **Allow remote control of this Mac**, and use each
matching permission action until Accessibility and Input Monitoring show
Granted. In VoiceOver settings, record the current voice and select **FarRelay
Remote Voice**. Return to FarRelay and choose **Test VoiceOver Feedback**;
navigate with VoiceOver in Finder, Safari, or System Settings. Restore the
original VoiceOver voice after the test.

## Testing and reporting

**Emergency Stop** is local: it stops forwarding, revokes control, and releases
held keys even when the controller is disconnected. Choose **Copy Diagnostic
Report** after testing and paste it into feedback. The report excludes SSH
credentials, channel values, typed input, and VoiceOver utterance contents.

Test provider availability; Finder, Safari, and System Settings navigation;
rapid VO-Right/VO-Left; interruption; Command-Tab; Command-Space; text
editing; buttons; host enable/disable; and reconnect. Report semantic feedback
separately from any system-audio observation.

## Quit and uninstall

Stop Remote Control, restore the original VoiceOver voice, and quit FarRelay.
To uninstall, drag FarRelay from Applications to Trash. No Gatekeeper bypass,
SIP change, `xattr`, or developer tools are required.
