# macOS VoiceOver Remote-Control Roadmap

Status: M2-prep implemented; M1 physical proof still pending

Priority: immediately after `TerminalSessionManager`, before Agents/Assistant implementation

Target hardware validation: Mac mini arrival, October 1, 2026

## Goal

Give FarRelay an NVDA-Remote-like control mode for a **single target Mac** such as the user's Mac mini.

The intended experience is:

```text
iPhone FarRelay
    -> Enter Mac Remote Control
    -> Mac mini VoiceOver
    -> navigate / interact / activate / read / type
    -> useful remote speech or semantic state returns to iPhone
    -> Exit Remote Control
```

This is not Mac-to-Mac Screen Sharing and does not require a second Mac.

The design goal is to control the Mac's **real VoiceOver environment**, not to build a second screen reader inside FarRelay.

## Research findings — September 2026

### 1. Primary path: VoiceOver's supported AppleScript bridge

Current VoiceOver Utility exposes an explicit setting named **Allow VoiceOver to be controlled with AppleScript**.

Independent inspection of VoiceOver's scripting dictionary, including the W3C AT Driver investigation, shows commands and properties useful to FarRelay such as:

- perform a VoiceOver command by name
- move the VoiceOver cursor left/right/up/down
- move into/out of an item
- press or perform the current action
- retrieve the last spoken phrase
- retrieve text under the VoiceOver cursor
- retrieve text under the keyboard cursor
- open VoiceOver menus and choosers

This is the preferred first implementation path because **VoiceOver itself remains responsible for navigation and screen-reader semantics**.

References:

- Apple VoiceOver Utility: https://support.apple.com/guide/voiceover/cpvougen/mac
- W3C AT Driver VoiceOver AppleScript investigation: https://github.com/w3c/at-driver/issues/74

Enabling VoiceOver AppleScript control must remain an explicit local user action. FarRelay must not bypass SIP/TCC or silently modify protected VoiceOver preferences.

### 2. macOS Accessibility API is the semantic verification/fallback layer

Apple's `AXUIElement` APIs are intended for assistive applications to communicate with and control accessible macOS applications.

They can provide:

- role
- label/title
- value
- available actions
- selected/enabled/expanded state
- focused application/window/UI element
- accessibility-change notifications

Useful references:

- https://developer.apple.com/documentation/applicationservices/axuielement_h
- https://developer.apple.com/documentation/applicationservices/carbon_accessibility/notifications

VoiceOver and keyboard focus are synchronized by default on macOS. That makes AX focused-element state useful for many normal interactions.

However, VoiceOver cursor tracking can be disabled. Therefore:

> `AXFocusedUIElement` must never be treated as a guaranteed public VoiceOver-cursor API.

Reference:

- https://support.apple.com/guide/voiceover/vo15534/mac

AX is a verification and fallback source, not a reason to replace real VoiceOver navigation.

### 3. Raw keyboard/event injection is a fallback

Quartz Event Services supports creating and posting keyboard events, including modifier state.

Use raw event injection for cases such as:

- ordinary typing
- Command-Tab
- Command-Space
- system/app shortcuts
- keys not represented by VoiceOver's scripting bridge
- compatibility fallback

Do not make blind `CGEvent` injection the primary VoiceOver-control protocol if semantic VoiceOver commands work.

Relevant APIs:

- `CGEventCreateKeyboardEvent`
- `CGEventPost`
- `CGEventFlags`
- `CGPreflightPostEventAccess`
- `CGRequestPostEventAccess`

References:

- https://developer.apple.com/documentation/coregraphics/cgevent/init(keyboardeventsource:virtualkey:keydown:)
- https://developer.apple.com/documentation/coregraphics/quartz-event-services
- https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess()

### 4. iPhone VoiceOver creates a hardware-keyboard conflict that must be designed around

Both iPhone VoiceOver and Mac VoiceOver can use Control+Option or Caps Lock as their VoiceOver modifier.

Therefore FarRelay must not assume that literal Mac VoiceOver chords will always arrive untouched at the iPhone app while local VoiceOver is enabled.

FarRelay should use an explicit **Remote Control mode** above raw input forwarding:

```text
physical keyboard/controller input
    -> FarRelay remote-control binding
    -> stable semantic Mac VoiceOver action
    -> RemoteIntent / host capability
    -> Mac VoiceOver adapter
```

Examples of stable semantic actions:

- `mac.voiceover.nextItem`
- `mac.voiceover.previousItem`
- `mac.voiceover.activate`
- `mac.voiceover.interact`
- `mac.voiceover.stopInteracting`
- `mac.voiceover.readCurrent`
- `mac.voiceover.readAll`
- `mac.remote.exitControl`

The exact IDs should follow the repository's existing stable-action conventions when implementation begins.

Raw chord forwarding can remain available where safe. Future controller mappings should consume the same semantic actions rather than inventing another control layer.

The remote-control mode must have a deterministic emergency exit action analogous in spirit to NVDA Remote's mode switch.

### 5. Preferred speech/feedback strategy

The first implementation should prefer semantic text/state over audio streaming.

Priority order:

1. VoiceOver AppleScript `last phrase` and VoiceOver-cursor text when available.
2. AX role/label/value/state as structured verification and fallback.
3. Optional exact VoiceOver audio streaming later if semantic feedback is insufficient.

Apple documents the user's ability to repeat/copy VoiceOver's last spoken phrase, which aligns with the scripting bridge's `last phrase` concept.

Reference:

- https://support.apple.com/guide/voiceover/vo2725/mac

### 6. Optional exact VoiceOver audio path

ScreenCaptureKit supports low-latency screen/audio capture and can filter audio at the application level.

That makes exact VoiceOver audio capture a plausible later fidelity feature if text/state feedback does not fully reproduce the experience the user wants.

It should not be required for the first remote-control MVP because it adds:

- screen/audio capture permission
- codec/transport work
- latency/buffering concerns
- mixing/ducking concerns with iPhone VoiceOver

References:

- https://developer.apple.com/documentation/screencapturekit
- https://developer.apple.com/videos/play/wwdc2022/10156/

### 7. XCUIVoiceOverService is promising but testing-only

Apple's newer `XCUIVoiceOverService` exposes extremely relevant operations including:

- `currentSpeech()`
- `moveForward()`
- `moveBackward()`
- `moveIn()`
- `moveOut()`
- enabling/disabling VoiceOver

Apple documents this API specifically as **programmatic VoiceOver control for UI testing** through XCUIAutomation.

Do not make production FarRelay depend on XCTest/XCUIAutomation.

It may be valuable for:

- automated validation
- regression tests on suitable real/simulator environments
- understanding Apple's semantic VoiceOver model
- monitoring whether Apple later exposes equivalent runtime APIs

Reference:

- https://developer.apple.com/documentation/xcuiautomation/xcuivoiceoverservice

## Proposed architecture

```text
iPhone FarRelay
    RemoteControlMode
        -> RemoteIntent / stable semantic action
            -> authenticated FarRelay Host connection
                -> macOS VoiceOver capability
                    primary: VoiceOver AppleScript bridge
                    verification/fallback: AXUIElement
                    raw-key fallback: CGEvent
                -> RemoteAccessibilityState
                    VoiceOver phrase/current text
                    AX role/label/value/state
                    active app/window
                    capability/permission/error state
```

Permissions and side effects remain deterministic outside any model or agent.

## Host capability model

A macOS `HostProfile` may expose an optional capability such as:

`macOS VoiceOver Remote Control`

Capability readiness should distinguish at least:

- VoiceOver available
- VoiceOver currently enabled/disabled
- VoiceOver AppleScript control enabled/disabled
- Accessibility client permission granted/denied
- PostEvent permission granted/denied when raw input fallback is needed
- AppleScript bridge probe success/failure

Do not infer remote-control readiness only from `platform == macOS`.

The capability should be discovered/reported by the host rather than hard-coded by the iOS client.

## Roadmap phases

### Phase M0 — API spike before physical Mac arrival

The first production-shaped host/protocol seam is implemented:

```text
FarRelay iPhone
    ↓
SSH exec
farrelay-host
    ↓
VoiceOverProvider
    ↓
macOS VoiceOver AppleScript bridge
```

This slice proves the host boundary. It does **not** claim that real VoiceOver
control works.

Implemented:

- `VoiceOverProvider` semantic operations (no raw AppleScript in protocol dispatch)
- macOS AppleScript provider via fixed `/usr/bin/osascript` templates
- Windows/Linux unsupported-platform results
- `voiceover.status`, `voiceover.move`, `voiceover.press`, `voiceover.state`
- platform-sensitive capability advertisement
- typed iOS `FarRelayHostClient` operations
- mocked/deterministic host and HostClient tests

Explicitly deferred from M0: AXUIElement, CGEvent, RemoteIntent/controller mapping, keyboard passthrough, voice commands, screen/audio streaming, and automatic VoiceOver/AppleScript enablement.

CI may compile and unit-test abstractions, but headless CI must not be treated as proof that real VoiceOver automation works. GitHub-hosted macOS runners may have VoiceOver AppleScript control disabled.

### Phase M0 physical Mac checklist — October 1

Do not claim success until these are physically tested on the Mac mini, in this order:

1. VoiceOver is running
2. AppleScript control is explicitly enabled (`Allow VoiceOver to be controlled with AppleScript`)
3. `farrelay-host` capabilities advertise VoiceOver support
4. `voiceover.status` succeeds
5. `voiceover.state` returns useful text
6. move right changes the real VoiceOver cursor
7. move left returns it
8. move into/out works on an interactive control/group
9. press activates the real VoiceOver item
10. state/last phrase changes after navigation

### Phase M1 — physical Mac proof, October 1 target

On the actual Mac mini, manually enable the required supported permissions and VoiceOver configuration.

Prove these capabilities in order:

1. detect VoiceOver availability/state
2. move real VoiceOver cursor to next item
3. move to previous item
4. interact with current item
5. stop interacting
6. activate/default action
7. retrieve last spoken phrase
8. retrieve current VoiceOver item text
9. type text into an editable field
10. send Command-Tab
11. send Command-Space
12. permission denial/revocation fails closed
13. disconnect/reconnect never leaves stuck modifiers or hidden capture state

Minimum manual validation applications:

- Finder
- System Settings
- Safari
- one native text-editing surface

Success gate:

> A blind user can navigate and activate meaningful UI on the Mac mini remotely, using VoiceOver semantics and returned feedback, without sighted assistance.

### Phase M2-prep — iPhone Remote Control shell (implemented; not physical proof)

The iPhone now has a production-shaped control session and accessible UI that
uses the typed Host API and deterministic fakes. This is **not** Phase M1 or
M2 completion. Physical VoiceOver control, AppleScript permissions on the Mac
mini, returned-speech sufficiency, and NVDA Remote parity remain October 1
validation items.

Implemented:

- Home → macOS HostProfile → Remote Control
- `MacRemoteControlSession` connection lifecycle over one structured `farrelay-host` exec
- profile-scoped SSH configuration and `farRelayHostCommand`
- capability probing and conservative VoiceOver status/state display
- provisional semantic buttons mapped to existing host operations
- serial action execution, truthful failure, disconnect/reconnect cleanup
- accessible native SwiftUI controls that inform without hijacking iPhone VoiceOver

Not in this slice:

- RemoteIntent-to-Mac mapping
- keyboard or controller capture
- a global Remote Control mode
- enabling VoiceOver or AppleScript remotely
- claiming real VoiceOver navigation works

### Phase M2 — FarRelay iPhone Remote Control mode

After October 1 physical validation, the same `MacRemoteControlSession` can
become the backend for a Mac RemoteIntent target and explicit Remote Control
mode.

Remaining M2 requirements:

- explicit Enter Remote Control
- explicit Exit Remote Control
- no hidden global keyboard capture
- announce whether input currently targets local FarRelay or the remote Mac
- semantic commands first
- configurable hardware-keyboard bindings
- stable action IDs compatible with the future controller adapter
- deterministic emergency exit
- release all held/raw input state on disconnect, app background, host failure, or exit
- local VoiceOver focus remains predictable

### Phase M3 — semantic feedback channel

Return structured state after actions where useful:

- VoiceOver phrase/current text
- active application
- active/focused window
- AX role
- label/title
- value
- selected/enabled/expanded state
- capability and permission errors

Do not steal iPhone VoiceOver focus merely because remote state changed.

Use the same principle as terminal live output:

> inform without hijacking.

### Phase M4 — broader VoiceOver command coverage

Add controlled semantic mappings for frequently used VoiceOver operations, including:

- next/previous item
- interact / stop interacting
- activate
- menus / Dock / desktop
- application/window chooser
- Item Chooser
- rotor navigation
- headings/links/form controls
- tables
- text navigation/granularity
- read current / read all
- Quick Nav where useful

Do not encode the product architecture as a giant list of physical keyboard chords. Physical bindings belong at the adapter/UI boundary; remote operations remain semantic.

### Phase M5 — optional exact VoiceOver audio streaming

Only if semantic phrase/state feedback proves insufficient, investigate low-latency VoiceOver audio streaming using ScreenCaptureKit.

Treat this as fidelity work rather than a prerequisite for remote control.

## Security and safety invariants

- use the existing authenticated FarRelay/SSH/Tailscale path; no public listening port is required
- never disable SIP
- do not depend on private `ScreenReaderCore` APIs for production
- require explicit macOS TCC and VoiceOver AppleScript permissions
- fail closed when permissions disappear
- raw modifier/key state must be released at every disconnect or mode-exit boundary
- never claim an action succeeded only because an event/command was sent
- keep agent/model permissions separate from direct remote-control permissions
- do not allow a model to bypass deterministic approval boundaries

## Relationship to existing roadmap

This work should begin **after `TerminalSessionManager` is stable** and before investing in Agents/Assistant product UI.

Reasoning:

1. `TerminalSessionManager` fixes the core multi-session workspace needed on both Windows and macOS.
2. macOS VoiceOver remote control is hardware/time-sensitive because the Mac mini arrives October 1.
3. Agents and Assistant can later consume the same `RemoteIntent` and host-capability abstractions rather than forcing a second redesign.

The future controller adapter should target the same semantic Mac VoiceOver actions defined here.

## Long-term acceptance target

The finished experience should feel analogous to NVDA Remote even though the implementation is different:

1. User opens the Mac mini in FarRelay.
2. User enters Remote Control.
3. Keyboard/controller actions target the Mac rather than ordinary local app commands.
4. The Mac's **real VoiceOver** performs navigation/actions.
5. FarRelay returns useful VoiceOver speech/semantic feedback to iPhone.
6. User exits Remote Control and immediately resumes normal local FarRelay/VoiceOver use.

The first version does not need every VoiceOver command. It must prove reliable navigation, interaction, activation, text entry, meaningful feedback, safe mode switching, permission handling, and recovery.