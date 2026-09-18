import SwiftUI
import UIKit

/// Hosts the UIKit responder path and the additive GameController path for an
/// attached physical keyboard. The view is intentionally non-interactive and
/// inaccessible: it never competes with the remote screen's VoiceOver order.
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
/// reserved locally on this NVDA-specific surface so a recognised fallback can
/// never leak as the Windows key before its number-row key is classified.
final class CaptureView: UIView {
    var bridge: BridgeClient?
    var settings: AppSettings?
    var diagnostics: InputDiagnosticStore?
    private var priorityDuplicateGate = PriorityRawDuplicateGate()
    private var functionDuplicateGate = FunctionKeyDuplicateGate()
    private var reservedFallbackUsages: Set<Int> = []
    private var pendingModifierKeys: [Int: UIKey] = [:]
    private var forwardedModifierUsages: Set<Int> = []
    private var fallbackModifierUsages: Set<Int> = []
    private var gameControllerCapture: GameControllerKeyboardCapture?

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
        if active {
            if gameControllerCapture == nil {
                let capture = GameControllerKeyboardCapture(owner: self)
                gameControllerCapture = capture
                capture.start()
            }
        } else {
            gameControllerCapture?.stop()
            gameControllerCapture = nil
            reservedFallbackUsages.removeAll()
            pendingModifierKeys.removeAll()
            forwardedModifierUsages.removeAll()
            fallbackModifierUsages.removeAll()
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

        // Buffer physical Control/Option/Shift only until the next source key
        // classifies the chord. This keeps modifier order irrelevant for the
        // Command fallback while adding no typing latency to ordinary chords.
        for key in keys where isPreservedModifier(key.keyCode) {
            claimed = handleModifier(key, pressed: pressed, bridge: bridge) || claimed
        }

        for key in keys where !isPreservedModifier(key.keyCode) {
            if CommandFunctionKeyFallback.isCommandKey(key.keyCode) {
                diagnostics?.observe(
                    source: .rawPress,
                    hidUsage: key.keyCode.rawValue,
                    modifiers: key.modifierFlags.rawValue,
                    pressed: pressed,
                    result: pressed ? "Command consumed locally for fallback classification" : "Command released locally"
                )
                claimed = true
                continue
            }
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
            let possibleVK = HIDToVK.vk(
                for: key,
                optionMapping: settings?.optionMapping ?? .alt,
                commandMapping: settings?.commandMapping ?? .alt
            )
            if let possibleVK, isFunctionVirtualKey(possibleVK) {
                if functionDuplicateGate.suppresses(virtualKey: possibleVK, pressed: pressed, source: .rawPress) {
                    diagnostics?.observe(source: .rawPress, hidUsage: key.keyCode.rawValue, modifiers: key.modifierFlags.rawValue, pressed: pressed, virtualKey: possibleVK, result: "deduplicated against another capture path")
                    claimed = true
                    continue
                }
                flushPendingModifiers(bridge)
                claimed = forwardRawKey(key, pressed: pressed, bridge: bridge, functionDedupAlreadyChecked: true) || claimed
                continue
            }
            flushPendingModifiers(bridge)
            claimed = forwardRawKey(key, pressed: pressed, bridge: bridge) || claimed
        }
        return claimed
    }

    private func handleModifier(_ key: UIKey, pressed: Bool, bridge: BridgeClient) -> Bool {
        let usage = key.keyCode.rawValue
        if pressed {
            pendingModifierKeys[usage] = key
            diagnostics?.observe(source: .rawPress, hidUsage: usage, modifiers: key.modifierFlags.rawValue, pressed: true, result: "modifier buffered for chord classification")
            return true
        }
        if pendingModifierKeys.removeValue(forKey: usage) != nil {
            diagnostics?.observe(source: .rawPress, hidUsage: usage, modifiers: key.modifierFlags.rawValue, pressed: false, result: "unpaired buffered modifier consumed")
            return true
        }
        if fallbackModifierUsages.remove(usage) != nil {
            diagnostics?.observe(source: .commandFallback, hidUsage: usage, modifiers: key.modifierFlags.rawValue, pressed: false, result: "fallback modifier source consumed")
            return true
        }
        if forwardedModifierUsages.remove(usage) != nil {
            return forwardRawKey(key, pressed: false, bridge: bridge)
        }
        return false
    }

    private func flushPendingModifiers(_ bridge: BridgeClient) {
        let pending = pendingModifierKeys.values.sorted { $0.keyCode.rawValue < $1.keyCode.rawValue }
        pendingModifierKeys.removeAll()
        for key in pending {
            forwardedModifierUsages.insert(key.keyCode.rawValue)
            _ = forwardRawKey(key, pressed: true, bridge: bridge)
        }
    }

    private func forwardRawKey(
        _ key: UIKey,
        pressed: Bool,
        bridge: BridgeClient,
        functionDedupAlreadyChecked: Bool = false
    ) -> Bool {
        let vk = HIDToVK.vk(
            for: key,
            optionMapping: settings?.optionMapping ?? .alt,
            commandMapping: settings?.commandMapping ?? .alt
        )
        diagnostics?.observe(
            source: .rawPress,
            hidUsage: key.keyCode.rawValue,
            modifiers: key.modifierFlags.rawValue,
            pressed: pressed,
            virtualKey: vk,
            result: vk == nil ? "unmapped HID usage" : "mapped"
        )
        guard let vk else { return false }
        if !functionDedupAlreadyChecked, isFunctionVirtualKey(vk), functionDuplicateGate.suppresses(
            virtualKey: vk, pressed: pressed, source: .rawPress
        ) {
            diagnostics?.observe(source: .rawPress, hidUsage: key.keyCode.rawValue, modifiers: key.modifierFlags.rawValue, pressed: pressed, virtualKey: vk, result: "deduplicated against another capture path")
            return true
        }
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
        fallbackModifierUsages.formUnion(pendingModifierKeys.keys)
        pendingModifierKeys.removeAll()
        if functionDuplicateGate.suppressesFallback(virtualKey: mapping.virtualKey) {
            diagnostics?.observe(source: .commandFallback, hidUsage: mapping.hidUsage.rawValue, modifiers: key.modifierFlags.rawValue, virtualKey: mapping.virtualKey, result: "deduplicated fallback event")
            return true
        }
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
        let reserved = ReservedKeyForwardingPolicy.registrations.map { registration in
            let command = UIKeyCommand(
                input: registration.input,
                modifierFlags: ReservedKeyForwardingPolicy.modifierFlags(for: registration.modifiers),
                action: #selector(handleReservedKeyCommand(_:))
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        let fallbacks = CommandFunctionKeyFallback.keyCommandRegistrations.map { registration in
            let command = UIKeyCommand(
                input: registration.input,
                modifierFlags: registration.modifiers,
                action: #selector(handleReservedKeyCommand(_:))
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return reserved + fallbacks
    }

    @objc private func handleReservedKeyCommand(_ command: UIKeyCommand) {
        guard let bridge, bridge.forwardingEnabled, let input = command.input else { return }
        if command.modifierFlags.contains(.command),
           let mapping = CommandFunctionKeyFallback.mapping(forInput: input) {
            reservedFallbackUsages.insert(mapping.hidUsage.rawValue)
            fallbackModifierUsages.formUnion(pendingModifierKeys.keys)
            pendingModifierKeys.removeAll()
            if functionDuplicateGate.suppressesFallback(virtualKey: mapping.virtualKey) {
                diagnostics?.observe(source: .commandFallback, hidUsage: mapping.hidUsage.rawValue, modifiers: command.modifierFlags.rawValue, virtualKey: mapping.virtualKey, result: "deduplicated fallback event")
                return
            }
            let results = bridge.forwardFunctionKeyTap(
                vk: mapping.virtualKey,
                modifiers: CommandFunctionKeyFallback.preservedModifiers(for: command.modifierFlags)
            )
            diagnostics?.observe(source: .commandFallback, hidUsage: mapping.hidUsage.rawValue, modifiers: command.modifierFlags.rawValue, virtualKey: mapping.virtualKey, result: fallbackDiagnosticResult(flags: command.modifierFlags, results: results))
            return
        }
        guard let transitions = ReservedKeyForwardingPolicy.transitions(
            for: input,
            modifierFlags: command.modifierFlags,
            optionMapping: settings?.optionMapping ?? .alt,
            commandMapping: settings?.commandMapping ?? .alt,
            includeCommand: false
        ) else {
            diagnostics?.observe(source: .keyCommand, modifiers: command.modifierFlags.rawValue, result: "unmapped key command")
            return
        }
        if let functionVK = ReservedKeyForwardingPolicy.vk(forInput: input),
           isFunctionVirtualKey(functionVK),
           functionDuplicateGate.suppresses(virtualKey: functionVK, pressed: true, source: .keyCommand) {
            diagnostics?.observe(source: .keyCommand, modifiers: command.modifierFlags.rawValue, virtualKey: functionVK, result: "deduplicated against another capture path")
            return
        }
        priorityDuplicateGate.recordPriorityTransitions(transitions)
        for transition in transitions {
            let result = bridge.forwardKey(vk: transition.vk, pressed: transition.pressed)
            diagnostics?.observe(source: .keyCommand, modifiers: command.modifierFlags.rawValue, pressed: transition.pressed, virtualKey: transition.vk, result: result.diagnosticText)
        }
    }

    func receiveGameControllerFunctionKey(vk: UInt16, pressed: Bool, modifiers: [UInt16]) {
        guard let bridge, bridge.forwardingEnabled else { return }
        if functionDuplicateGate.suppresses(virtualKey: vk, pressed: pressed, source: .gameController) {
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

    private func isPreservedModifier(_ usage: UIKeyboardHIDUsage) -> Bool {
        switch usage {
        case .keyboardLeftControl, .keyboardRightControl,
             .keyboardLeftAlt, .keyboardRightAlt,
             .keyboardLeftShift, .keyboardRightShift:
            true
        default:
            false
        }
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
