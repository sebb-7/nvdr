# FarRelay Roadmap

Updated: 2026-09-21
Active branch: `feat/remote-intent-v2-recovery`

## Implemented / validated

### Remote control foundation
- Capability-routed `RemoteIntent` architecture with explicit targets and no unsafe fallback.
- NVDA Remote Windows target with raw key and chord input.
- Controller lifecycle handling with held-key ownership, repeats, release safety, and target leases.
- Configurable DualSense controller mappings.
- Base and Extended layers.
- Layer behavior: hold for momentary, tap for one-shot, double-tap to lock.
- D-pad, sticks, shoulder/trigger buttons, Options/Create/Home, stick presses, and touchpad press modeled as controller inputs.
- F1-F12 and modifier/key combinations validated earlier in the project.

### Text Mode / BSI
- Local iPhone text editor designed for VoiceOver Braille Screen Input.
- Append-at-end and suffix deletion mirrored to the Windows target.
- Remote Backspace handling avoids duplicate deletion.
- Unsupported Unicode fails locally instead of corrupting remote text.
- Common US-keyboard punctuation mapping expanded, including shifted punctuation such as `?`, `!`, `@`, braces, pipe, underscore, plus, quotes, angle brackets, and tilde.
- User has physically validated BSI Text Mode for real remote typing.

### Quick Navigation / rotor
- Quick Navigation is a local mode that does not depend on the normal controller mapping lookup while active.
- Rotor sections currently include:
  - Quick Bar
  - Headings
  - Links
  - Form controls
  - Edit fields
  - Buttons
  - Landmarks
  - Tables
  - Lists
- Current candidate interaction:
  - Horizontal DualSense touchpad swipe changes rotor section.
  - Right-stick Up/Down moves within the selected section.
  - Cross activates the current remote item outside Quick Bar.
  - In Quick Bar, Cross executes the highlighted action locally and does not send Enter.
  - Circle/Create exits Quick Navigation.
- Touchpad swipe detector uses a horizontal threshold and allows one rotor step per swipe.
- Current provisional Quick Bar actions:
  - Show Desktop
  - NVDA Menu
  - Next Application
  - Elements List
  - Read Window Title
  - Report Focus
- Current touchpad-rotor implementation still requires exact-head iOS CI and physical controller validation.

### Windows/NVDA recovery
- Fixed recovery task uses NVDA's signed `nvda_slave.exe launchNVDA` path instead of directly launching the UIAccess executable.
- Recovery readiness rejects outdated task definitions.
- Restart success requires a real NVDA PID transition; Task Scheduler acceptance alone is not considered success.
- Canonical Windows recovery candidate: `0.2.0-beta.5`.
- FarRelay Host and Windows Updater CI are green for the recovery candidate.
- User physically validated iPhone -> SSH -> farrelay-host -> scheduled task -> NVDA restart on the G14.
- Travel readiness checker validates SSH, host version, recovery task, power settings, and related prerequisites.

### Distribution
- Windows private updater exists with authenticated manifest/download design, hash/size validation, rollback, and daily scheduled update support.
- Private Cloudflare Worker + D1 + private R2 design exists.
- Private updater publication/manifest flow is not yet fully operational for normal tester updates, so manual local install/build is still sometimes required.

### Interaction feedback
- FarRelay interaction sound assets and sound intent plumbing exist.
- Interaction sounds are distinct from streaming Windows application audio.

## Queued next

### 1. Configurable Quick Bar using the existing mapping/action system
Do not create a separate command model.

- Reuse the existing controller `ControllerAction` / keyboard/chord mapping model for Quick Bar entries.
- Allow add/remove/reorder.
- Preserve a default recommended Quick Bar layout.
- Extend the action model only where a FarRelay-native semantic action is required.
- Add Restore Default Quick Bar.

### 2. Repeat Last Quick Bar Action
- Add a first-class mappable action: `Repeat Last Quick Bar Action`.
- Recommended default binding: Extended layer + Cross.
- Store only the last successful repeatable Quick Bar action.
- Session-scoped: clear on FarRelay relaunch.
- Explicitly exclude destructive/recovery actions from repeat.
- Reuse the same mapping system so the user can bind Repeat Last anywhere.

### 3. RemSound audio streaming integration
Integrate RemSound into FarRelay rather than requiring a separate iOS receiver app. RemSound is MIT-licensed and its iOS companion speaks the same protocol, so prefer protocol-compatible receiver integration inside FarRelay over a second independent audio stack/app.

#### Integration direction
- FarRelay should own the iOS audio session and receive RemSound-compatible audio itself.
- Avoid requiring the user to keep a separate RemSound iOS app active alongside FarRelay.
- Reuse the RemSound wire protocol / codec behavior where practical; preserve required MIT attribution if code is reused directly.
- Keep RemSound as the Windows-side audio sender initially; FarRelay becomes the integrated iOS receiver/control surface.
- Later consider whether FarRelay should provision/control the Windows sender service as part of the normal host installer.

#### Audio control panel
- Master stream On/Off.
- List active Windows audio applications/sessions.
- Per-app Enable/Disable streaming.
- Per-app volume/mute where supported.
- Persist safe per-app preferences.
- Screen-reader-first labels/state announcements.
- Connection, latency, and reconnect status.
- Optional Quick Bar actions for Stream Audio On/Off and opening the audio panel.

#### Desired use cases
- Stream music from a selected Windows music app while controlling the G14 from iPhone.
- Include selected apps without forwarding every Windows system sound.
- If technically possible, independently include/exclude NVDA speech.
- Audio failure must never break keyboard/NVDA/SSH control.

### 4. Physical validation
- Validate touchpad rotor on a real DualSense.
- Validate Quick Bar Cross never sends Enter.
- Validate Cross sends Enter after moving to Headings/Links/etc.
- Validate BSI punctuation on the remote Windows target.
- Build a fresh TestFlight after the exact-head iOS CI is green.

### 5. Travel hardening
- Configure NVDA Remote auto-connect.
- Copy the appropriate NVDA settings for sign-in/secure screens and test carefully.
- Test lock/sign-in, reboot, lid-closed, and cellular/off-home-network scenarios.
- Finish private updater publication so tester machines no longer require local Cargo builds.
