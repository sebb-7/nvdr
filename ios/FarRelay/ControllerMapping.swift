import Foundation
import Observation

/// Stable, FarRelay-owned inputs. They intentionally do not store GameController objects.
enum ControllerInput: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case cross, circle, square, triangle
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case leftStickPress, rightStickPress
    case leftStickUp, leftStickDown, leftStickLeft, leftStickRight
    case rightStickUp, rightStickDown, rightStickLeft, rightStickRight
    case options, create, home, touchpadPress

    var id: String { rawValue }
    var label: String {
        switch self {
        case .dpadUp: "D-pad Up"; case .dpadDown: "D-pad Down"; case .dpadLeft: "D-pad Left"; case .dpadRight: "D-pad Right"
        case .cross: "Cross"; case .circle: "Circle"; case .square: "Square"; case .triangle: "Triangle"
        case .leftShoulder: "L1"; case .rightShoulder: "R1"; case .leftTrigger: "L2"; case .rightTrigger: "R2"
        case .leftStickPress: "L3 / Left Stick Press"; case .rightStickPress: "R3 / Right Stick Press"
        case .leftStickUp: "Left Stick Up"; case .leftStickDown: "Left Stick Down"; case .leftStickLeft: "Left Stick Left"; case .leftStickRight: "Left Stick Right"
        case .rightStickUp: "Right Stick Up"; case .rightStickDown: "Right Stick Down"; case .rightStickLeft: "Right Stick Left"; case .rightStickRight: "Right Stick Right"
        case .options: "Options"; case .create: "Create / Share"; case .home: "Home"; case .touchpadPress: "Touchpad Press"
        }
    }
}

enum ControllerHardware: String, Codable, Sendable { case dualSense }

/// Typed Windows virtual-key destination. The raw value is a stable profile identifier,
/// while `virtualKey` is the only transport-facing representation.
enum WindowsKeyboardKey: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case backspace, tab, enter, escape, space, pageUp, pageDown, end, home, left, up, right, down, insert, delete
    case capsLock, pause, printScreen, scrollLock, numLock, contextMenu
    case shift, leftShift, rightShift, control, leftControl, rightControl, alt, leftAlt, rightAlt, windows
    case numpad0, numpad1, numpad2, numpad3, numpad4, numpad5, numpad6, numpad7, numpad8, numpad9, numpadMultiply, numpadAdd, numpadSubtract, numpadDecimal, numpadDivide
    case semicolon, equal, comma, minus, period, slash, grave, leftBracket, backslash, rightBracket, quote
    case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case digit0, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24

    var id: String { rawValue }
    var label: String { rawValue.replacing("digit", with: "").uppercased().replacing("Numpad", with: "Numpad ") }
    var virtualKey: UInt16 {
        switch self {
        case .backspace: 0x08; case .tab: 0x09; case .enter: 0x0D; case .shift: 0x10; case .control: 0x11; case .alt: 0x12
        case .pause: 0x13; case .capsLock: 0x14; case .escape: 0x1B; case .space: 0x20; case .pageUp: 0x21; case .pageDown: 0x22; case .end: 0x23; case .home: 0x24
        case .left: 0x25; case .up: 0x26; case .right: 0x27; case .down: 0x28; case .printScreen: 0x2C; case .insert: 0x2D; case .delete: 0x2E
        case .windows: 0x5B; case .contextMenu: 0x5D; case .numpad0: 0x60; case .numpad1: 0x61; case .numpad2: 0x62; case .numpad3: 0x63; case .numpad4: 0x64; case .numpad5: 0x65; case .numpad6: 0x66; case .numpad7: 0x67; case .numpad8: 0x68; case .numpad9: 0x69; case .numpadMultiply: 0x6A; case .numpadAdd: 0x6B; case .numpadSubtract: 0x6D; case .numpadDecimal: 0x6E; case .numpadDivide: 0x6F
        case .f1: 0x70; case .f2: 0x71; case .f3: 0x72; case .f4: 0x73; case .f5: 0x74; case .f6: 0x75; case .f7: 0x76; case .f8: 0x77; case .f9: 0x78; case .f10: 0x79; case .f11: 0x7A; case .f12: 0x7B; case .f13: 0x7C; case .f14: 0x7D; case .f15: 0x7E; case .f16: 0x7F; case .f17: 0x80; case .f18: 0x81; case .f19: 0x82; case .f20: 0x83; case .f21: 0x84; case .f22: 0x85; case .f23: 0x86; case .f24: 0x87
        case .numLock: 0x90; case .scrollLock: 0x91; case .leftShift: 0xA0; case .rightShift: 0xA1; case .leftControl: 0xA2; case .rightControl: 0xA3; case .leftAlt: 0xA4; case .rightAlt: 0xA5
        case .semicolon: 0xBA; case .equal: 0xBB; case .comma: 0xBC; case .minus: 0xBD; case .period: 0xBE; case .slash: 0xBF; case .grave: 0xC0; case .leftBracket: 0xDB; case .backslash: 0xDC; case .rightBracket: 0xDD; case .quote: 0xDE
        case .a: 0x41; case .b: 0x42; case .c: 0x43; case .d: 0x44; case .e: 0x45; case .f: 0x46; case .g: 0x47; case .h: 0x48; case .i: 0x49; case .j: 0x4A; case .k: 0x4B; case .l: 0x4C; case .m: 0x4D; case .n: 0x4E; case .o: 0x4F; case .p: 0x50; case .q: 0x51; case .r: 0x52; case .s: 0x53; case .t: 0x54; case .u: 0x55; case .v: 0x56; case .w: 0x57; case .x: 0x58; case .y: 0x59; case .z: 0x5A
        case .digit0: 0x30; case .digit1: 0x31; case .digit2: 0x32; case .digit3: 0x33; case .digit4: 0x34; case .digit5: 0x35; case .digit6: 0x36; case .digit7: 0x37; case .digit8: 0x38; case .digit9: 0x39
        }
    }
}

enum ControllerKeyboardModifier: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case shift, control, alt, windows, nvda
    var id: String { rawValue }
    var label: String { rawValue == "nvda" ? "NVDA modifier" : rawValue.capitalized }
}

struct KeyboardAction: Codable, Hashable, Sendable {
    var key: WindowsKeyboardKey
    var modifiers: Set<ControllerKeyboardModifier> = []
}

enum ControllerAction: Codable, Hashable, Sendable { case keyboard(KeyboardAction) }

struct ControllerBinding: Codable, Hashable, Identifiable, Sendable {
    var sourceInput: ControllerInput
    var action: ControllerAction?
    var id: ControllerInput { sourceInput }
}

struct ControllerProfile: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var name: String = "Default Controller Profile"
    var controller: ControllerHardware = .dualSense
    var bindings: [ControllerBinding] = ControllerInput.allCases.map { .init(sourceInput: $0, action: nil) }

    func action(for input: ControllerInput) -> ControllerAction? { bindings.first { $0.sourceInput == input }?.action }
    mutating func setAction(_ action: ControllerAction?, for input: ControllerInput) {
        if let index = bindings.firstIndex(where: { $0.sourceInput == input }) { bindings[index].action = action }
        else { bindings.append(.init(sourceInput: input, action: action)) }
    }

    /// Older profile bytes can omit a controller input introduced by a later
    /// app build. Add only unassigned slots; duplicate source identifiers are
    /// ambiguous and are rejected rather than silently choosing one mapping.
    func normalizedBindingSlots() -> ControllerProfile? {
        guard Set(bindings.map(\.sourceInput)).count == bindings.count else { return nil }
        var normalized = self
        for input in ControllerInput.allCases where normalized.bindings.contains(where: { $0.sourceInput == input }) == false {
            normalized.bindings.append(.init(sourceInput: input, action: nil))
        }
        return normalized
    }
}

enum ControllerProfileLoadResult: Equatable { case profile(ControllerProfile), uninitialized, malformedOrUnsupported }

struct ControllerProfileStore {
    let defaults: UserDefaults
    let key: String
    func load() -> ControllerProfileLoadResult {
        guard let data = defaults.data(forKey: key) else { return .uninitialized }
        guard let profile = try? JSONDecoder().decode(ControllerProfile.self, from: data),
              profile.schemaVersion == ControllerProfile.currentSchemaVersion,
              let normalized = profile.normalizedBindingSlots() else { return .malformedOrUnsupported }
        return .profile(normalized)
    }
    func save(_ profile: ControllerProfile) { defaults.set(try? JSONEncoder().encode(profile), forKey: key) }
}

@Observable @MainActor
final class ControllerMappingSettings {
    private(set) var activeProfile: ControllerProfile
    private let store: ControllerProfileStore
    /// The adapter releases any action it began before an edit is applied, so
    /// changing or clearing a mapping cannot leave its former remote key held.
    var willChangeActiveProfile: (@MainActor () -> Void)?
    init(defaults: UserDefaults = .standard) {
        store = .init(defaults: defaults, key: "farrelay.controllerProfile.v1")
        switch store.load() { case .profile(let profile): activeProfile = profile; case .uninitialized, .malformedOrUnsupported: activeProfile = .init() }
    }
    func setAction(_ action: ControllerAction?, for input: ControllerInput) {
        willChangeActiveProfile?()
        activeProfile.setAction(action, for: input)
        store.save(activeProfile)
    }
}
