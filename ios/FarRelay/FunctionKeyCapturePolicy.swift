import Foundation
import GameController
import UIKit

/// Build 28 diagnostics proved that UIKit can arm the priority F1-F12 surface
/// without delivering a physical function-row event on every keyboard/device
/// path. Keep the validated UIKit raw + UIKeyCommand routes and install the
/// additive GCKeyboard fallback, which is intentionally restricted to F1-F12.
/// Cross-source duplicates are suppressed before they reach the transport.
enum PhysicalFunctionRowCapturePolicy {
    static let installsGameControllerCapture = true

    static var priorityRegistrations: [ReservedKeyForwardingPolicy.Registration] {
        ReservedKeyForwardingPolicy.registrations
    }
}

/// The only local Command chords reserved by the NVDA Remote keyboard surface.
/// They are deliberately physical-key based rather than character based, so
/// keyboard layouts cannot turn a fallback chord into remote text input.
enum CommandFunctionKeyFallback {
    struct Mapping: Equatable {
        let hidUsage: UIKeyboardHIDUsage
        let input: String
        let virtualKey: UInt16
    }

    static let mappings: [Mapping] = [
        .init(hidUsage: .keyboard1, input: "1", virtualKey: VK.f1),
        .init(hidUsage: .keyboard2, input: "2", virtualKey: VK.f1 + 1),
        .init(hidUsage: .keyboard3, input: "3", virtualKey: VK.f1 + 2),
        .init(hidUsage: .keyboard4, input: "4", virtualKey: VK.f1 + 3),
        .init(hidUsage: .keyboard5, input: "5", virtualKey: VK.f1 + 4),
        .init(hidUsage: .keyboard6, input: "6", virtualKey: VK.f1 + 5),
        .init(hidUsage: .keyboard7, input: "7", virtualKey: VK.f1 + 6),
        .init(hidUsage: .keyboard8, input: "8", virtualKey: VK.f1 + 7),
        .init(hidUsage: .keyboard9, input: "9", virtualKey: VK.f1 + 8),
        .init(hidUsage: .keyboard0, input: "0", virtualKey: VK.f1 + 9),
        .init(hidUsage: .keyboardHyphen, input: "-", virtualKey: VK.f1 + 10),
        .init(hidUsage: .keyboardEqualSign, input: "=", virtualKey: VK.f1 + 11)
    ]

    static func mapping(for usage: UIKeyboardHIDUsage) -> Mapping? {
        mappings.first { $0.hidUsage == usage }
    }

    static func mapping(forInput input: String) -> Mapping? {
        mappings.first { $0.input == input }
    }

    /// Command is consumed only by a recognised fallback. Control, Option,
    /// Shift, and Caps Lock remain Windows modifiers for the synthesized
    /// F-key chord.
    static func preservedModifiers(for flags: UIKeyModifierFlags) -> [UInt16] {
        var modifiers: [UInt16] = []
        if flags.contains(.control) { modifiers.append(VK.control) }
        if flags.contains(.alternate) { modifiers.append(VK.menu) }
        if flags.contains(.shift) { modifiers.append(VK.shift) }
        if flags.contains(.alphaShift) { modifiers.append(VK.capital) }
        return modifiers
    }

    static func modifierDescription(for flags: UIKeyModifierFlags) -> String {
        var names: [String] = []
        if flags.contains(.control) { names.append("Control") }
        if flags.contains(.alternate) { names.append("Alt") }
        if flags.contains(.shift) { names.append("Shift") }
        if flags.contains(.alphaShift) { names.append("Caps Lock") }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    static func isCommandKey(_ usage: UIKeyboardHIDUsage) -> Bool {
        usage == .keyboardLeftGUI || usage == .keyboardRightGUI
    }

    /// UIKeyCommand needs one registration for each exact modifier set. These
    /// are a secondary public UIKit route; the raw path remains available.
    static var keyCommandRegistrations: [(input: String, modifiers: UIKeyModifierFlags)] {
        let optional: [UIKeyModifierFlags] = [.control, .alternate, .shift]
        let modifierSets = (0..<(1 << optional.count)).map { mask in
            optional.enumerated().reduce(into: UIKeyModifierFlags.command) { flags, pair in
                if (mask & (1 << pair.offset)) != 0 { flags.insert(pair.element) }
            }
        }
        return mappings.flatMap { mapping in
            modifierSets.map { (input: mapping.input, modifiers: $0) }
        }
    }
}

/// The authoritative function-key tap sequence used by `BridgeClient`. It
/// owns only modifiers that the raw path has not already pressed, so a
/// fallback can never release a physically-held modifier.
struct FunctionKeyTransmissionPlan: Equatable {
    struct Transition: Equatable {
        let vk: UInt16
        let pressed: Bool
    }

    let transitions: [Transition]

    init(virtualKey: UInt16, modifiers: [UInt16], alreadyPressed: Set<UInt16>) {
        let owned = modifiers.filter { !alreadyPressed.contains($0) }
        transitions = owned.map { Transition(vk: $0, pressed: true) }
            + [Transition(vk: virtualKey, pressed: true), Transition(vk: virtualKey, pressed: false)]
            + owned.reversed().map { Transition(vk: $0, pressed: false) }
    }
}

/// Testable state for the GCKeyboard lifecycle. The framework callback itself
/// is not mockable in a simulator, but its F-key down/up/disconnect policy is.
struct GameControllerFunctionKeyState: Equatable {
    private(set) var activeVirtualKeys: Set<UInt16> = []

    mutating func receive(virtualKey: UInt16, pressed: Bool) {
        if pressed {
            activeVirtualKeys.insert(virtualKey)
        } else {
            activeVirtualKeys.remove(virtualKey)
        }
    }

    mutating func releaseAllOnDisconnect() -> [UInt16] {
        let keys = activeVirtualKeys.sorted()
        activeVirtualKeys.removeAll()
        return keys
    }
}

/// Maps only the physical F-row exposed by GameController. F13 and later are
/// intentionally outside the Build 18 capture scope.
enum GameControllerFunctionKeyMapping {
    static func virtualKey(for keyCode: GCKeyCode) -> UInt16? {
        switch keyCode {
        case .F1: VK.f1
        case .F2: VK.f1 + 1
        case .F3: VK.f1 + 2
        case .F4: VK.f1 + 3
        case .F5: VK.f1 + 4
        case .F6: VK.f1 + 5
        case .F7: VK.f1 + 6
        case .F8: VK.f1 + 7
        case .F9: VK.f1 + 8
        case .F10: VK.f1 + 9
        case .F11: VK.f1 + 10
        case .F12: VK.f1 + 11
        default: nil
        }
    }

    static func modifiers(from keyboard: GCKeyboardInput) -> [UInt16] {
        let isPressed: (GCKeyCode) -> Bool = { code in
            keyboard.button(forKeyCode: code)?.isPressed == true
        }
        var modifiers: [UInt16] = []
        if isPressed(.leftControl) || isPressed(.rightControl) { modifiers.append(VK.control) }
        if isPressed(.leftAlt) || isPressed(.rightAlt) { modifiers.append(VK.menu) }
        if isPressed(.leftShift) || isPressed(.rightShift) { modifiers.append(VK.shift) }
        if isPressed(.capsLock) { modifiers.append(VK.capital) }
        return modifiers
    }
}

/// A narrow, short-lived cross-source gate. It suppresses only the matching
/// transition observed through a *different* capture API, so repeated physical
/// F-keys from the same API remain responsive.
struct FunctionKeyDuplicateGate {
    enum Source: Hashable {
        case rawPress
        case keyCommand
        case gameController
        case rawFallback
        case keyCommandFallback
    }

    private struct Event: Hashable {
        let virtualKey: UInt16
        let pressed: Bool
        let modifierFlags: Int
        let originUsage: Int
    }

    private var recent: [Event: (source: Source, at: Date)] = [:]
    private let window: TimeInterval = 0.075

    mutating func suppresses(
        virtualKey: UInt16,
        pressed: Bool,
        source: Source,
        modifierFlags: Int = 0,
        originUsage: Int,
        now: Date = .now
    ) -> Bool {
        recent = recent.filter { now.timeIntervalSince($0.value.at) <= window }
        let event = Event(
            virtualKey: virtualKey,
            pressed: pressed,
            modifierFlags: modifierFlags,
            originUsage: originUsage
        )
        defer { recent[event] = (source, now) }
        guard let prior = recent[event] else { return false }
        return prior.source != source && now.timeIntervalSince(prior.at) <= window
    }
}
