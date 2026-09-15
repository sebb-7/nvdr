import Foundation
import UIKit

/// Windows virtual-key codes — only the subset we actually emit. Mirrors
/// `src/vk.rs` so the wire side and the iOS side agree.
enum VK {
    static let back: UInt16 = 0x08
    static let tab: UInt16 = 0x09
    static let `return`: UInt16 = 0x0D
    static let shift: UInt16 = 0x10
    static let control: UInt16 = 0x11
    static let menu: UInt16 = 0x12 // Alt
    static let pause: UInt16 = 0x13
    static let capital: UInt16 = 0x14
    static let escape: UInt16 = 0x1B
    static let space: UInt16 = 0x20
    static let prior: UInt16 = 0x21
    static let next: UInt16 = 0x22
    static let end: UInt16 = 0x23
    static let home: UInt16 = 0x24
    static let left: UInt16 = 0x25
    static let up: UInt16 = 0x26
    static let right: UInt16 = 0x27
    static let down: UInt16 = 0x28
    static let insert: UInt16 = 0x2D
    static let delete: UInt16 = 0x2E
    static let lwin: UInt16 = 0x5B
    static let rwin: UInt16 = 0x5C
    static let apps: UInt16 = 0x5D
    static let numpad0: UInt16 = 0x60
    static let f1: UInt16 = 0x70
    static let numlock: UInt16 = 0x90
    static let scroll: UInt16 = 0x91
    static let lshift: UInt16 = 0xA0
    static let rshift: UInt16 = 0xA1
    static let lcontrol: UInt16 = 0xA2
    static let rcontrol: UInt16 = 0xA3
    static let lmenu: UInt16 = 0xA4
    static let rmenu: UInt16 = 0xA5
    static let oem1: UInt16 = 0xBA      // ; :
    static let oemPlus: UInt16 = 0xBB   // = +
    static let oemComma: UInt16 = 0xBC  // , <
    static let oemMinus: UInt16 = 0xBD  // - _
    static let oemPeriod: UInt16 = 0xBE // . >
    static let oem2: UInt16 = 0xBF      // / ?
    static let oem3: UInt16 = 0xC0      // ` ~
    static let oem4: UInt16 = 0xDB      // [ {
    static let oem5: UInt16 = 0xDC      // \ |
    static let oem6: UInt16 = 0xDD      // ] }
    static let oem7: UInt16 = 0xDE      // ' "
}

/// Translate a `UIKey` (raw HID usage from a Bluetooth keyboard) into a
/// Windows VK code suitable for the `key` IPC command.
///
/// Returns `nil` for keys we don't have a mapping for; the caller drops the
/// transition rather than guessing. We deliberately don't try to handle
/// shifted-character composition — every UIKey corresponds to a physical key
/// transition, and the remote NVDA cares about the physical key.
///
/// The `optionMapping` / `commandMapping` parameters control how Mac-style
/// modifier keys are forwarded — Option / Command don't exist on Windows
/// per se; the user picks which Windows modifier each one stands in for.
enum HIDToVK {
    enum Side { case left, right }

    static func remappedModifier(_ mapping: ModifierMapping, side: Side) -> UInt16? {
        switch (mapping, side) {
        case (.alt, .left): return VK.lmenu
        case (.alt, .right): return VK.rmenu
        case (.win, .left): return VK.lwin
        case (.win, .right): return VK.rwin
        case (.ctrl, .left): return VK.lcontrol
        case (.ctrl, .right): return VK.rcontrol
        case (.none, _): return nil
        }
    }

    static func vk(
        for key: UIKey,
        optionMapping: ModifierMapping = .alt,
        commandMapping: ModifierMapping = .alt
    ) -> UInt16? {
        let code = key.keyCode
        let raw = code.rawValue
        // Letters: HID 0x04..0x1D → VK 0x41..0x5A
        if raw >= UIKeyboardHIDUsage.keyboardA.rawValue, raw <= UIKeyboardHIDUsage.keyboardZ.rawValue {
            return UInt16(0x41 + (raw - UIKeyboardHIDUsage.keyboardA.rawValue))
        }
        // Top-row digits: 1..9 then 0 (HID order is 1,2,…,9,0)
        if raw >= UIKeyboardHIDUsage.keyboard1.rawValue, raw <= UIKeyboardHIDUsage.keyboard9.rawValue {
            return UInt16(0x31 + (raw - UIKeyboardHIDUsage.keyboard1.rawValue))
        }
        if let functionVK = functionVK(forKeyboardUsage: Int(raw)) { return functionVK }
        // Numpad 1..9
        if raw >= UIKeyboardHIDUsage.keypad1.rawValue, raw <= UIKeyboardHIDUsage.keypad9.rawValue {
            return VK.numpad0 + 1 + UInt16(raw - UIKeyboardHIDUsage.keypad1.rawValue)
        }
        switch code {
        case .keyboard0: return 0x30
        // Punctuation (US layout)
        case .keyboardHyphen: return VK.oemMinus
        case .keyboardEqualSign: return VK.oemPlus
        case .keyboardOpenBracket: return VK.oem4
        case .keyboardCloseBracket: return VK.oem6
        case .keyboardBackslash: return VK.oem5
        case .keyboardNonUSPound: return VK.oem5
        case .keyboardSemicolon: return VK.oem1
        case .keyboardQuote: return VK.oem7
        case .keyboardGraveAccentAndTilde: return VK.oem3
        case .keyboardComma: return VK.oemComma
        case .keyboardPeriod: return VK.oemPeriod
        case .keyboardSlash: return VK.oem2
        // Whitespace / control
        case .keyboardSpacebar: return VK.space
        case .keyboardReturnOrEnter, .keypadEnter: return VK.return
        case .keyboardTab: return VK.tab
        case .keyboardDeleteOrBackspace: return VK.back
        case .keyboardEscape: return VK.escape
        case .keyboardCapsLock: return VK.capital
        case .keyboardDeleteForward: return VK.delete
        case .keyboardInsert: return VK.insert
        case .keyboardHome: return VK.home
        case .keyboardEnd: return VK.end
        case .keyboardPageUp: return VK.prior
        case .keyboardPageDown: return VK.next
        // Arrows
        case .keyboardLeftArrow: return VK.left
        case .keyboardRightArrow: return VK.right
        case .keyboardUpArrow: return VK.up
        case .keyboardDownArrow: return VK.down
        // Modifiers — distinguish left vs right
        case .keyboardLeftShift: return VK.lshift
        case .keyboardRightShift: return VK.rshift
        case .keyboardLeftControl: return VK.lcontrol
        case .keyboardRightControl: return VK.rcontrol
        // Mac Option (= HID LeftAlt/RightAlt) and Command (= HID LeftGUI/
        // RightGUI) routed through the user-chosen mapping.
        case .keyboardLeftAlt: return remappedModifier(optionMapping, side: .left)
        case .keyboardRightAlt: return remappedModifier(optionMapping, side: .right)
        case .keyboardLeftGUI: return remappedModifier(commandMapping, side: .left)
        case .keyboardRightGUI: return remappedModifier(commandMapping, side: .right)
        case .keyboardApplication: return VK.apps
        // Numpad
        case .keypad0: return VK.numpad0
        case .keypadNumLock: return VK.numlock
        // Pause / scroll lock
        case .keyboardPause: return VK.pause
        case .keyboardScrollLock: return VK.scroll
        default:
            return nil
        }
    }

    /// Logical mapping seam used by both the raw UIKit path and deterministic
    /// conformance tests. USB HID assigns consecutive usages to F1...F24.
    static func functionVK(forKeyboardUsage usage: Int) -> UInt16? {
        let f1 = Int(UIKeyboardHIDUsage.keyboardF1.rawValue)
        let f12 = Int(UIKeyboardHIDUsage.keyboardF12.rawValue)
        let f13 = Int(UIKeyboardHIDUsage.keyboardF13.rawValue)
        let f24 = Int(UIKeyboardHIDUsage.keyboardF24.rawValue)
        if usage >= f1, usage <= f12 {
            return VK.f1 + UInt16(usage - f1)
        }
        if usage >= f13, usage <= f24 {
            return VK.f1 + 12 + UInt16(usage - f13)
        }
        return nil
    }
}

/// The public UIKit priority-command surface used when VoiceOver or UIKit
/// reserves a hardware key before the raw `UIPress` responder path sees it.
/// UIKit publishes F1 through F12 (`UIKeyCommand.f1` … `.f12`), but not F13
/// through F24. The latter therefore remain on the existing raw HID path.
enum ReservedKeyForwardingPolicy {
    enum Modifier: CaseIterable, Hashable {
        case shift
        case control
        case alternate
        case command
    }

    struct Registration: Hashable {
        let input: String
        let modifiers: Set<Modifier>
    }

    static let unmodifiedInputs = [
        UIKeyCommand.inputUpArrow,
        UIKeyCommand.inputDownArrow,
        UIKeyCommand.inputLeftArrow,
        UIKeyCommand.inputRightArrow,
        UIKeyCommand.inputEscape
    ]

    static let functionInputs = [
        UIKeyCommand.f1, UIKeyCommand.f2, UIKeyCommand.f3, UIKeyCommand.f4,
        UIKeyCommand.f5, UIKeyCommand.f6, UIKeyCommand.f7, UIKeyCommand.f8,
        UIKeyCommand.f9, UIKeyCommand.f10, UIKeyCommand.f11, UIKeyCommand.f12
    ]

    /// A UIKeyCommand matches an exact modifier set, so register every public
    /// modifier combination for F-keys. This includes the NVDA-relevant
    /// Shift/Control/Option/Command chords without guessing private inputs.
    static let functionModifierSets: [Set<Modifier>] = [
        [], [.shift], [.control], [.alternate], [.command],
        [.shift, .control], [.shift, .alternate], [.shift, .command],
        [.control, .alternate], [.control, .command], [.alternate, .command],
        [.shift, .control, .alternate], [.shift, .control, .command],
        [.shift, .alternate, .command], [.control, .alternate, .command],
        [.shift, .control, .alternate, .command]
    ]

    static var registrations: [Registration] {
        unmodifiedInputs.map { Registration(input: $0, modifiers: []) }
            + functionInputs.flatMap { input in
                functionModifierSets.map { Registration(input: input, modifiers: $0) }
            }
    }

    static func vk(forInput input: String) -> UInt16? {
        switch input {
        case UIKeyCommand.inputUpArrow: return VK.up
        case UIKeyCommand.inputDownArrow: return VK.down
        case UIKeyCommand.inputLeftArrow: return VK.left
        case UIKeyCommand.inputRightArrow: return VK.right
        case UIKeyCommand.inputEscape: return VK.escape
        default:
            guard let index = functionInputs.firstIndex(of: input) else { return nil }
            return VK.f1 + UInt16(index)
        }
    }

    static func modifiers(for flags: UIKeyModifierFlags) -> Set<Modifier> {
        var result: Set<Modifier> = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.alternate) { result.insert(.alternate) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    static func modifierFlags(for modifiers: Set<Modifier>) -> UIKeyModifierFlags {
        modifiers.reduce(into: []) { flags, modifier in
            switch modifier {
            case .shift: flags.insert(.shift)
            case .control: flags.insert(.control)
            case .alternate: flags.insert(.alternate)
            case .command: flags.insert(.command)
            }
        }
    }

    /// UIKeyCommand reports modifier families but not left/right physical
    /// sides. The priority fallback intentionally uses the left VK for mapped
    /// Option/Command; raw HID delivery still preserves actual side data.
    static func modifierVKs(
        for modifiers: Set<Modifier>,
        optionMapping: ModifierMapping,
        commandMapping: ModifierMapping
    ) -> [UInt16] {
        let order: [Modifier] = [.control, .alternate, .shift, .command]
        return order.compactMap { modifier in
            guard modifiers.contains(modifier) else { return nil }
            switch modifier {
            case .shift: return VK.shift
            case .control: return VK.control
            case .alternate: return HIDToVK.remappedModifier(optionMapping, side: .left)
            case .command: return HIDToVK.remappedModifier(commandMapping, side: .left)
            }
        }
    }

    static func transitions(
        for input: String,
        modifierFlags: UIKeyModifierFlags,
        optionMapping: ModifierMapping,
        commandMapping: ModifierMapping
    ) -> [(vk: UInt16, pressed: Bool)]? {
        guard let key = vk(forInput: input) else { return nil }
        let modifiers = modifierVKs(
            for: modifiers(for: modifierFlags),
            optionMapping: optionMapping,
            commandMapping: commandMapping
        )
        return modifiers.map { ($0, true) }
            + [(key, true), (key, false)]
            + modifiers.reversed().map { ($0, false) }
    }
}

/// Suppresses raw delivery only after a priority command has claimed the same
/// physical transition. It is state-based rather than timer-based so a raw and
/// UIKeyCommand double delivery cannot produce duplicate taps or stranded
/// modifier releases.
struct PriorityRawDuplicateGate {
    private var pendingRawReleases: Set<UInt16> = []

    mutating func recordPriorityTransitions(_ transitions: [(vk: UInt16, pressed: Bool)]) {
        pendingRawReleases.formUnion(transitions.map { normalizedKey($0.vk) })
    }

    mutating func suppressesRaw(vk: UInt16, pressed: Bool) -> Bool {
        let key = normalizedKey(vk)
        guard pendingRawReleases.contains(key) else { return false }
        if !pressed { pendingRawReleases.remove(key) }
        return true
    }

    private func normalizedKey(_ vk: UInt16) -> UInt16 {
        switch vk {
        case VK.lshift, VK.rshift, VK.shift: VK.shift
        case VK.lcontrol, VK.rcontrol, VK.control: VK.control
        case VK.lmenu, VK.rmenu, VK.menu: VK.menu
        case VK.lwin, VK.rwin: VK.lwin
        default: vk
        }
    }
}
