import SwiftUI
import UIKit

/// Hosts the UIKit responder path for an attached physical keyboard. Direct
/// F1-F12 priority commands are authoritative because that path is physically
/// validated. The view is intentionally non-interactive and inaccessible.
struct KeyboardCapture: UIViewRepresentable {
    let bridge: BridgeClient
    let settings: AppSettings
    let diagnostics: InputDiagnosticStore

    func makeUIView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.bridge = bridge
        view.settings = settings
        view.diagnostics = diagnostics
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        Task { @MainActor in _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: CaptureView, context: Context) {
        view.bridge = bridge
        view.settings = settings
        view.diagnostics = diagnostics
        view.setKeyboardCaptureActive(bridge.forwardingEnabled)
        if bridge.forwardingEnabled {
            if view.window != nil, !view.isFirstResponder {
                Task { @MainActor in _ = view.becomeFirstResponder() }
            }
        } else if view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ uiView: CaptureView, coordinator: Void) {
        uiView.setKeyboardCaptureActive(false)
        _ = uiView.resignFirstResponder()
    }
}

/// First-responder UIView that observes raw UIKit keyboard events. Command is
/// buffered only until the next key identifies one of the twelve reserved
/// fallback chords; every other Command chord is sent as the Windows key.
final class CaptureView: UIView {
    var bridge: BridgeClient?
    var settings: AppSettings?
    var diagnostics: InputDiagnosticStore?
    private var priorityDuplicateGate = PriorityRawDuplicateGate()
    private var functionDuplicateGate = FunctionKeyDuplicateGate()
    private var reservedFallbackUsages: Set<Int> = []
    private var pendingCommandKeys: [Int: UIKey] = [:]
    private var forwardedCommandUsages: Set<Int> = []
    private var consumedFallbackCommandUsages: Set<Int> = []
    private var gameControllerCapture: GameControllerKeyboardCapture?
    private var keyboardCaptureActive = false

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            Task { @MainActor in
                let active = self.becomeFirstResponder()
                self.diagnostics?.observe(source: .responder, result: active ? "first responder active" : "first responder request failed")
            }
            setKeyboardCaptureActive(bridge?.forwardingEnabled == true)
        } else {
            setKeyboardCaptureActive(false)
        }
    }

    func setKeyboardCaptureActive(_ active: Bool) {
        guard active != keyboardCaptureActive else { return }
        keyboardCaptureActive = active

        if active {
            // Keep the physically validated UIKit responder + priority
            // UIKeyCommand path authoritative. Do not install GCKeyboard in
            // front of it; that later layer has not been physically validated
            // against the media-key regression.
            if PhysicalFunctionRowCapturePolicy.installsGameControllerCapture {
                let capture = GameControllerKeyboardCapture(owner: self)
                gameControllerCapture = capture
                capture.start()
            }
            diagnostics?.observe(
                source: .responder,
                result: "direct priority F1-F12 capture armed"
            )
        } else {
            gameControllerCapture?.stop()
            gameControllerCapture = nil
            reservedFallbackUsages.removeAll()
            pendingCommandKeys.removeAll()
            forwardedCommandUsages.removeAll()
            consumedFallbackCommandUsages.removeAll()
        }
    }

    /// Ask UIKit for priority only within the active remote keyboard surface.
    @objc func _wantsPriorityOverSystemBehaviorWhenKeyboardEvent() -> Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, pressed: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, pressed: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        _ = forward(presses, pressed: false)
        super.pressesCancelled(presses, with: event)
    }

    @discardableResult
    private func forward(_ presses: Set<UIPress>, pressed: Bool) -> Bool {
        guard let bridge, bridge.forwardingEnabled else { return false }
        let keys = presses.compactMap(\.key)
        var claimed = false

        // Command is the only modifier that needs a one-key classification
        // delay. Control, Option, Shift, and Caps Lock remain raw remote
        // modifiers and are therefore never globally intercepted.
        for key in keys where CommandFunctionKeyFallback.isCommandKey(key.keyCode) {
            if CommandFunctionKeyFallback.isCommandKey(key.keyCode) {
                claimed = handleCommand(key, pressed: pressed, bridge: bridge) || claimed
            }
        }

        for key in keys where !CommandFunctionKeyFallback.isCommandKey(key.keyCode) {
            if let mapping = CommandFunctionKeyFallback.mapping(for: key.keyCode) {
                if pressed, key.modifierFlags.contains(.command) {
                    claimed = handleFallbackRaw(mapping, key: key, pressed: true, bridge: bridge) || claimed
                    continue
                }
                if !pressed, reservedFallbackUsages.contains(mapping.hidUsage.rawValue) {
                    claimed = handleFallbackRaw(mapping, key: key, pressed: false, bridge: bridge) || claimed
                    continue
                }
            }
            flushPendingCommand(bridge)
            // Match the physically validated direct path: raw F1-F12 are
            // forwarded immediately. Priority UIKeyCommand duplication is
            // handled by PriorityRawDuplicateGate, not by a timed cross-source
            // gate.
            claimed = forwardRawKey(key, pressed: pressed, bridge: bridge) || claimed
        }
        return claimed
    }

    private func handleCommand(_ key: UIKey, pressed: Bool, bridge: BridgeClient) -> Bool {
        let usage = key.keyCode.rawValue
        if pressed {
            pendingCommandKeys[usage] = key
            diagnostics?.observe(source: .rawPress, hidUsage: usage, modifiers: key.modifierFlags.rawValue, pressed: true, result: "Command buffered for fallback classification")
            return true
        }
        if let pending = pendingCommandKeys.removeValue(forKey: usage) {
            _ = forwardRawKey(pending, pressed: true, bridge: bridge)
            return forwardRawKey(key, pressed: false, bridge: bridge)
        }
        if consumedFallbackCommandUsages.remove(usage) != nil {
            diagnostics?.observe(source: .commandFallback, hidUsage: usage, modifiers: key.modifierFlags.rawValue, pressed: false, result: "fallback Command consumed")
            return true
        }
        if forwardedCommandUsages.remove(usage) != nil {
            return forwardRawKey(key, pressed: false, bridge: bridge)
        }
        return false
    }

    private func flushPendingCommand(_ bridge: BridgeClient) {
        let pending = pendingCommandKeys.values.sorted { $0.keyCode.rawValue < $1.keyCode.rawValue }
        pendingCommandKeys.removeAll()
        for key in pending {
            forwardedCommandUsages.insert(key.keyCode.rawValue)
            _ = forwardRawKey(key, pressed: true, bridge: bridge)
        }
    }

    private func forwardRawKey(
        _ key: UIKey,
        pressed: Bool,
        bridge: BridgeClient
    ) -> Bool {
        let vk = remoteVK(for: key)
        diagnostics?.observe(
            source: .rawPress,
            hidUsage: key.keyCode.rawValue,
            modifiers: key.modifierFlags.rawValue,
            pressed: pressed,
            virtualKey: vk,
            result: vk == nil ? "unmapped HID usage" : "mapped"
        )
        guard let vk else { return false }
        if priorityDuplicateGate.suppressesRaw(vk: vk, pressed: pressed) {
            diagnostics?.observe(source: .rawPress, hidUsage: key.keyCode.rawValue, modifiers: key.modifierFlags.rawValue, pressed: pressed, virtualKey: vk, result: "suppressed priority-command duplicate")
            return true
        }
        let result = bridge.forwardKey(vk: vk, pressed: pressed)
        diagnostics?.observe(source: .rawPress, hidUsage: key.keyCode.rawValue, modifiers: key.modifierFlags.rawValue, pressed: pressed, virtualKey: vk, result: result.diagnosticText)
        return true
    }

    private func handleFallbackRaw(
        _ mapping: CommandFunctionKeyFallback.Mapping,
        key: UIKey,
        pressed: Bool,
        bridge: BridgeClient
    ) -> Bool {
        guard pressed else {
            reservedFallbackUsages.remove(mapping.hidUsage.rawValue)
            diagnostics?.observe(source: .commandFallback, hidUsage: mapping.hidUsage.rawValue, modifiers: key.modifierFlags.rawValue, pressed: false, virtualKey: mapping.virtualKey, result: "fallback source key consumed")
            return true
        }
        reservedFallbackUsages.insert(mapping.hidUsage.rawValue)
        consumedFallbackCommandUsages.formUnion(pendingCommandKeys.keys)
        pendingCommandKeys.removeAll()
        let results = bridge.forwardFunctionKeyTap(
            vk: mapping.virtualKey,
            modifiers: CommandFunctionKeyFallback.preservedModifiers(for: key.modifierFlags)
        )
        diagnostics?.observe(
            source: .commandFallback,
            hidUsage: mapping.hidUsage.rawValue,
            modifiers: key.modifierFlags.rawValue,
            virtualKey: mapping.virtualKey,
            result: fallbackDiagnosticResult(flags: key.modifierFlags, results: results)
        )
        return true
    }

    override var keyCommands: [UIKeyCommand]? {
        guard bridge?.forwardingEnabled == true else { return [] }

        // Keep the exact physically validated priority surface: arrows,
        // Escape, and F1-F12 with their modifier combinations. Command-number
        // fallback still exists in raw presses, but its 96 additional
        // UIKeyCommands are intentionally not installed in front of the
        // direct function row.
        return PhysicalFunctionRowCapturePolicy.priorityRegistrations.map { registration in
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
            optionMapping: .alt,
            commandMapping: .win
        ) else {
            diagnostics?.observe(
                source: .keyCommand,
                modifiers: command.modifierFlags.rawValue,
                result: "unmapped key command"
            )
            return
        }

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

    func receiveGameControllerFunctionKey(vk: UInt16, pressed: Bool, modifiers: [UInt16]) {
        guard let bridge, bridge.forwardingEnabled else { return }
        if functionDuplicateGate.suppresses(
            virtualKey: vk,
            pressed: pressed,
            source: .gameController,
            modifierFlags: modifierFlags(for: modifiers),
            originUsage: functionHIDUsage(for: vk)
        ) {
            diagnostics?.observe(source: .gameController, pressed: pressed, virtualKey: vk, result: "deduplicated against another capture path")
            return
        }
        let results = bridge.forwardFunctionKey(vk: vk, pressed: pressed, modifiers: modifiers)
        diagnostics?.observe(source: .gameController, pressed: pressed, virtualKey: vk, result: diagnosticSummary(results))
    }

    func gameControllerKeyboardConnected() {
        diagnostics?.observe(source: .gameController, result: "keyboard connected")
    }

    func gameControllerKeyboardDisconnected(releasing virtualKeys: [UInt16]) {
        guard let bridge else { return }
        for vk in virtualKeys {
            let results = bridge.releaseFunctionKey(vk: vk)
            diagnostics?.observe(source: .gameController, pressed: false, virtualKey: vk, result: "keyboard disconnected; logical key released; \(diagnosticSummary(results))")
        }
        diagnostics?.observe(source: .gameController, result: "keyboard disconnected")
    }

    private func remoteVK(for key: UIKey) -> UInt16? {
        // The active remote surface has a fixed Windows-oriented modifier
        // contract. Settings elsewhere may be customised, but physical
        // keyboard forwarding must keep Option=Alt and Command=Windows.
        HIDToVK.vk(for: key, optionMapping: .alt, commandMapping: .win)
    }

    private func functionHIDUsage(for virtualKey: UInt16) -> Int {
        Int(UIKeyboardHIDUsage.keyboardF1.rawValue) + Int(virtualKey - VK.f1)
    }

    private func modifierFlags(for modifiers: [UInt16]) -> Int {
        modifiers.reduce(0) { $0 | Int($1) }
    }

    private func isFunctionVirtualKey(_ vk: UInt16) -> Bool {
        vk >= VK.f1 && vk <= VK.f1 + 11
    }

    private func fallbackDiagnosticResult(flags: UIKeyModifierFlags, results: [InputForwardingResult]) -> String {
        "local Command and source key consumed; remote F-key synthesized; preserved modifiers: \(CommandFunctionKeyFallback.modifierDescription(for: flags)); \(diagnosticSummary(results))"
    }

    private func diagnosticSummary(_ results: [InputForwardingResult]) -> String {
        let messages = results.map(\.diagnosticText)
        return messages.contains { $0.hasPrefix("rejected:") }
            ? messages.joined(separator: "; ")
            : "queued for transport write; host receipt unconfirmed"
    }
}
