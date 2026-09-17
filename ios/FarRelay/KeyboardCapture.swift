import SwiftUI
import UIKit

/// Hosts a `UIView` that becomes first responder so attached Bluetooth
/// keyboard events flow through `pressesBegan`/`pressesEnded`. UIKit is the
/// only path that exposes raw HID press events; SwiftUI's keyboard shortcuts
/// abstract too aggressively (no key-up, no individual modifiers).
///
/// Mirrors the Python add-on's `_hook_keyDown` / `_hook_keyUp` in
/// `addon/globalPlugins/farrelayBridge/__init__.py`: each press becomes one
/// `key vk pressed=1` IPC line; each release becomes `key vk pressed=0`.
struct KeyboardCapture: UIViewRepresentable {
    let bridge: BridgeClient
    let settings: AppSettings
    let diagnostics: InputDiagnosticStore

    func makeUIView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.bridge = bridge
        v.settings = settings
        v.diagnostics = diagnostics
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        Task { @MainActor in _ = v.becomeFirstResponder() }
        return v
    }

    func updateUIView(_ view: CaptureView, context: Context) {
        view.bridge = bridge
        view.settings = settings
        view.diagnostics = diagnostics
        if bridge.forwardingEnabled {
            if view.window != nil, !view.isFirstResponder {
                Task { @MainActor in _ = view.becomeFirstResponder() }
            }
        } else if view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ uiView: CaptureView, coordinator: Void) {
        _ = uiView.resignFirstResponder()
    }
}

/// First-responder UIView that observes Bluetooth keyboard events and
/// forwards them to the bridge.
final class CaptureView: UIView {
    var bridge: BridgeClient?
    var settings: AppSettings?
    var diagnostics: InputDiagnosticStore?
    private var priorityDuplicateGate = PriorityRawDuplicateGate()

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            Task { @MainActor in
                let active = self.becomeFirstResponder()
                self.diagnostics?.observe(source: .responder, result: active ? "first responder active" : "first responder request failed")
            }
        }
    }

    /// Make sure the system doesn't pre-empt our keys with default behaviors
    /// (e.g. Cmd+Tab analogues, focus changes). With this true, every key
    /// reaches `pressesBegan` first.
    @objc func _wantsPriorityOverSystemBehaviorWhenKeyboardEvent() -> Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, pressed: true) {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, pressed: false) {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A cancelled press is functionally a release as far as the slave is
        // concerned — emit the up so we don't strand a modifier.
        _ = forward(presses, pressed: false)
        super.pressesCancelled(presses, with: event)
    }

    /// Returns true if at least one press in the set was claimed (forwarded).
    /// When forwarding is off we always return false so the system can route
    /// the event normally (e.g. keep-alive scrolling, tab focus).
    @discardableResult
    private func forward(_ presses: Set<UIPress>, pressed: Bool) -> Bool {
        guard let bridge, bridge.forwardingEnabled else { return false }
        let optionMap = settings?.optionMapping ?? .alt
        let commandMap = settings?.commandMapping ?? .alt
        var claimed = false
        for press in presses {
            guard let key = press.key else { continue }
            let vk = HIDToVK.vk(for: key, optionMapping: optionMap, commandMapping: commandMap)
            diagnostics?.observe(
                source: .rawPress,
                hidUsage: key.keyCode.rawValue,
                modifiers: key.modifierFlags.rawValue,
                pressed: pressed,
                virtualKey: vk,
                result: vk == nil ? "unmapped HID usage" : "mapped"
            )
            guard let vk else { continue }
            if priorityDuplicateGate.suppressesRaw(vk: vk, pressed: pressed) {
                diagnostics?.observe(source: .rawPress, hidUsage: key.keyCode.rawValue, modifiers: key.modifierFlags.rawValue, pressed: pressed, virtualKey: vk, result: "suppressed duplicate")
                claimed = true
                continue
            }
            let result = bridge.forwardKey(vk: vk, pressed: pressed)
            diagnostics?.observe(source: .rawPress, hidUsage: key.keyCode.rawValue, modifiers: key.modifierFlags.rawValue, pressed: pressed, virtualKey: vk, result: result.diagnosticText)
            claimed = true
        }
        return claimed
    }

    override var keyCommands: [UIKeyCommand]? {
        // Register the strongest public UIKit command path whenever FarRelay
        // forwarding is enabled, including while VoiceOver is running.
        // `wantsPriorityOverSystemBehavior` requests precedence; it does not
        // prove that VoiceOver will yield every reserved key on device.
        guard bridge?.forwardingEnabled == true else { return [] }
        return ReservedKeyForwardingPolicy.registrations.map { registration in
            let command = UIKeyCommand(
                input: registration.input,
                modifierFlags: ReservedKeyForwardingPolicy.modifierFlags(for: registration.modifiers),
                action: #selector(handleReservedKeyCommand(_:))
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func handleReservedKeyCommand(_ command: UIKeyCommand) {
        guard let bridge, bridge.forwardingEnabled, let input = command.input else { return }
        guard let transitions = ReservedKeyForwardingPolicy.transitions(
                for: input,
                modifierFlags: command.modifierFlags,
                optionMapping: settings?.optionMapping ?? .alt,
                commandMapping: settings?.commandMapping ?? .alt
              ) else {
            diagnostics?.observe(source: .keyCommand, modifiers: command.modifierFlags.rawValue, result: "unmapped key command")
            return
        }
        // UIKeyCommand does not expose key-up callbacks. Reconstruct the full
        // Windows chord as a deterministic tap, then suppress a matching raw
        // path if UIKit happens to deliver both representations.
        priorityDuplicateGate.recordPriorityTransitions(transitions)
        for transition in transitions {
            let result = bridge.forwardKey(vk: transition.vk, pressed: transition.pressed)
            diagnostics?.observe(
                source: .keyCommand,
                modifiers: command.modifierFlags.rawValue,
                pressed: transition.pressed,
                virtualKey: transition.vk,
                result: result.diagnosticText
            )
        }
    }
}
