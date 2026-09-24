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

enum WindowsKeyboardKeyGroup: String, CaseIterable, Identifiable, Sendable {
    case actionKeys = "Action keys"
    case lettersAndNumbers = "Letters and numbers"
    case functionKeys = "Function keys"
    case numpadAndSymbols = "Numpad and symbols"

    var id: String { rawValue }

    var keys: [WindowsKeyboardKey] {
        switch self {
        case .actionKeys:
            [
                .backspace, .tab, .enter, .escape, .space,
                .pageUp, .pageDown, .end, .home, .left, .up, .right, .down,
                .insert, .delete, .capsLock, .pause, .printScreen, .scrollLock,
                .numLock, .contextMenu, .shift, .leftShift, .rightShift,
                .control, .leftControl, .rightControl, .alt, .leftAlt,
                .rightAlt, .windows
            ]
        case .lettersAndNumbers:
            [
                .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
                .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
                .digit0, .digit1, .digit2, .digit3, .digit4,
                .digit5, .digit6, .digit7, .digit8, .digit9
            ]
        case .functionKeys:
            [
                .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
                .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20, .f21, .f22, .f23, .f24
            ]
        case .numpadAndSymbols:
            [
                .numpad0, .numpad1, .numpad2, .numpad3, .numpad4,
                .numpad5, .numpad6, .numpad7, .numpad8, .numpad9,
                .numpadMultiply, .numpadAdd, .numpadSubtract, .numpadDecimal,
                .numpadDivide, .semicolon, .equal, .comma, .minus, .period,
                .slash, .grave, .leftBracket, .backslash, .rightBracket, .quote
            ]
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

struct ControllerStickyModifierAction: Codable, Hashable, Sendable {
    static let maximumHeldModifiers = 3

    var modifiers: Set<ControllerKeyboardModifier>
    var tapKey: WindowsKeyboardKey?

    init(modifier: ControllerKeyboardModifier) {
        modifiers = [modifier]
        tapKey = nil
    }

    init(
        modifiers: Set<ControllerKeyboardModifier>,
        tapKey: WindowsKeyboardKey? = nil
    ) {
        self.modifiers = modifiers
        self.tapKey = tapKey
    }

    var isValid: Bool {
        !modifiers.isEmpty && modifiers.count <= Self.maximumHeldModifiers
    }

    private enum CodingKeys: String, CodingKey {
        case modifiers
        case tapKey
        case modifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try container.decodeIfPresent(
            Set<ControllerKeyboardModifier>.self,
            forKey: .modifiers
        ) {
            modifiers = decoded
        } else if let legacy = try container.decodeIfPresent(
            ControllerKeyboardModifier.self,
            forKey: .modifier
        ) {
            modifiers = [legacy]
        } else {
            modifiers = []
        }
        tapKey = try container.decodeIfPresent(WindowsKeyboardKey.self, forKey: .tapKey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encodeIfPresent(tapKey, forKey: .tapKey)
    }
}

/// A profile action remains platform-independent until the adapter resolves it
/// to a RemoteIntent. The non-keyboard cases are intentionally local modes,
/// so a future semantic NVDA protocol can replace keyboard shims without
/// changing controller UX or profile data.
enum ControllerAction: Codable, Hashable, Sendable {
    case keyboard(KeyboardAction)
    case stickyModifier(ControllerStickyModifierAction)
    case layer(ControllerLayerAction)
    case quickNavigation(QuickNavigationAction)
    case farRelay(FarRelayControllerAction)
}

struct ControllerLayerAction: Codable, Hashable, Sendable {
    var layerID: String
    init(layerID: String = ControllerLayerDefinition.extendedID) { self.layerID = layerID }
}

enum QuickNavigationAction: String, Codable, Hashable, Sendable { case toggle }
enum FarRelayControllerAction: String, Codable, Hashable, Sendable {
    case textMode
    case quickCommandMode
    case repeatLastQuickBar
    case repeatLastQuickCommand
    case nextProfile
    case previousProfile
}

extension ControllerAction {
    /// A mapped remote Escape is a control-plane command, even when a local
    /// controller mode is active. It must be claimed before Quick Navigation,
    /// text entry, or command mode can reinterpret the physical button.
    var sendsRemoteEscape: Bool {
        guard case .keyboard(let keyboard) = self else { return false }
        return keyboard.key == .escape
    }

    var isRepeatableQuickBarAction: Bool {
        if case .keyboard = self { return true }
        return false
    }

    var isAllowedInQuickBar: Bool {
        switch self {
        case .keyboard, .farRelay:
            return true
        case .stickyModifier, .layer, .quickNavigation:
            return false
        }
    }

    var displayLabel: String {
        switch self {
        case .keyboard(let keyboard):
            let modifiers = keyboard.modifiers.map(\.label).sorted()
            return (modifiers + [keyboard.key.label]).joined(separator: "+")
        case .stickyModifier(let sticky):
            let held = sticky.modifiers.map(\.label).sorted().joined(separator: "+")
            if let tapKey = sticky.tapKey {
                return "Hold \(held), tap \(tapKey.label)"
            }
            return held.isEmpty ? "Hold Modifier" : "Hold \(held)"
        case .layer(let layer):
            return "\(layer.layerID.capitalized) layer"
        case .quickNavigation:
            return "NVDA Quick Navigation"
        case .farRelay(let action):
            switch action {
            case .textMode: return "Text Mode"
            case .quickCommandMode: return "Quick Command Mode"
            case .repeatLastQuickBar: return "Repeat Last Quick Bar Action"
            case .repeatLastQuickCommand: return "Repeat Last Command"
            case .nextProfile: return "Next Profile"
            case .previousProfile: return "Previous Profile"
            }
        }
    }
}

struct QuickBarEntry: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var action: ControllerAction?

    var label: String { action?.displayLabel ?? "Unassigned" }

    init(id: UUID = UUID(), action: ControllerAction?) {
        self.id = id
        self.action = action
    }

    static var recommended: [QuickBarEntry] {
        [
            .init(action: .keyboard(.init(key: .d, modifiers: [.windows]))),
            .init(action: .keyboard(.init(key: .n, modifiers: [.nvda]))),
            .init(action: .keyboard(.init(key: .tab, modifiers: [.alt]))),
            .init(action: .keyboard(.init(key: .f7, modifiers: [.nvda]))),
            .init(action: .keyboard(.init(key: .t, modifiers: [.nvda]))),
            .init(action: .keyboard(.init(key: .tab, modifiers: [.nvda]))),
            .init(action: .keyboard(.init(key: .r, modifiers: [.windows]))),
            .init(action: .keyboard(.init(key: .l, modifiers: [.control]))),
            .init(action: .keyboard(.init(key: .s, modifiers: [.windows]))),
            .init(action: .keyboard(.init(key: .e, modifiers: [.windows]))),
            .init(action: .keyboard(.init(key: .f4, modifiers: [.alt])))
        ]
    }
}

struct ControllerLayerDefinition: Codable, Hashable, Identifiable, Sendable {
    static let extendedID = "extended"
    var id: String
    var name: String
    var bindings: [ControllerBinding]

    func action(for input: ControllerInput) -> ControllerAction? {
        bindings.first { $0.sourceInput == input }?.action
    }

    mutating func setAction(_ action: ControllerAction?, for input: ControllerInput) {
        if let index = bindings.firstIndex(where: { $0.sourceInput == input }) {
            bindings[index].action = action
        } else {
            bindings.append(.init(sourceInput: input, action: action))
        }
    }
}

struct ControllerBinding: Codable, Hashable, Identifiable, Sendable {
    var sourceInput: ControllerInput
    var action: ControllerAction?
    var id: ControllerInput { sourceInput }
}

struct ControllerProfile: Codable, Hashable, Identifiable, Sendable {
    static let currentSchemaVersion = 6
    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var name: String = "Default Controller Profile"
    var controller: ControllerHardware = .dualSense
    var bindings: [ControllerBinding] = ControllerInput.allCases.map { .init(sourceInput: $0, action: nil) }
    /// Base remains `bindings` for backward-compatible v1 migration. Named
    /// layers keep their own stable input slots for future custom layers.
    var layers: [ControllerLayerDefinition] = []
    var quickBar: [QuickBarEntry] = QuickBarEntry.recommended
    var quickNavigationOrder: [QuickNavigationCategory] = QuickNavigationCategory.defaultOrder
    var quickNavigationAutoExitAfterAction: Bool = true

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, controller, bindings, layers, quickBar
        case quickNavigationOrder, quickNavigationAutoExitAfterAction
    }

    init(
        schemaVersion: Int = ControllerProfile.currentSchemaVersion,
        id: UUID = UUID(),
        name: String = "Default Controller Profile",
        controller: ControllerHardware = .dualSense,
        bindings: [ControllerBinding] = ControllerInput.allCases.map { .init(sourceInput: $0, action: nil) },
        layers: [ControllerLayerDefinition] = [],
        quickBar: [QuickBarEntry] = QuickBarEntry.recommended,
        quickNavigationOrder: [QuickNavigationCategory] = QuickNavigationCategory.defaultOrder,
        quickNavigationAutoExitAfterAction: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.controller = controller
        self.bindings = bindings
        self.layers = layers
        self.quickBar = quickBar
        self.quickNavigationOrder = quickNavigationOrder
        self.quickNavigationAutoExitAfterAction = quickNavigationAutoExitAfterAction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Default Controller Profile"
        controller = try container.decodeIfPresent(ControllerHardware.self, forKey: .controller) ?? .dualSense
        bindings = try container.decodeIfPresent([ControllerBinding].self, forKey: .bindings) ?? []
        // v1 pre-dates named layers. Treat absence as an empty layer list so
        // the explicit migration below can preserve the base profile safely.
        layers = try container.decodeIfPresent([ControllerLayerDefinition].self, forKey: .layers) ?? []
        // v1/v2 pre-date Quick Bar persistence. Only old schemas receive the
        // recommended defaults; an explicitly empty v3 Quick Bar stays empty.
        quickBar = try container.decodeIfPresent([QuickBarEntry].self, forKey: .quickBar)
            ?? (schemaVersion < 3 ? QuickBarEntry.recommended : [])
        quickNavigationOrder = try container.decodeIfPresent(
            [QuickNavigationCategory].self,
            forKey: .quickNavigationOrder
        ) ?? QuickNavigationCategory.defaultOrder
        quickNavigationAutoExitAfterAction = try container.decodeIfPresent(
            Bool.self,
            forKey: .quickNavigationAutoExitAfterAction
        ) ?? true
    }

    func action(for input: ControllerInput) -> ControllerAction? { bindings.first { $0.sourceInput == input }?.action }
    mutating func setAction(_ action: ControllerAction?, for input: ControllerInput) {
        if let index = bindings.firstIndex(where: { $0.sourceInput == input }) { bindings[index].action = action }
        else { bindings.append(.init(sourceInput: input, action: action)) }
    }

    func action(for input: ControllerInput, layerID: String?) -> ControllerAction? {
        guard let layerID else { return action(for: input) }
        return layers.first { $0.id == layerID }?.action(for: input)
    }

    static func blank(name: String) -> ControllerProfile {
        let emptyBindings = ControllerInput.allCases.map {
            ControllerBinding(sourceInput: $0, action: nil)
        }
        let extended = ControllerLayerDefinition(
            id: ControllerLayerDefinition.extendedID,
            name: "Extended",
            bindings: emptyBindings
        )
        return ControllerProfile(
            name: name,
            bindings: emptyBindings,
            layers: [extended],
            quickBar: [],
            quickNavigationOrder: QuickNavigationCategory.defaultOrder
        )
    }

    static func newDefault(name: String = "Default Controller Profile") -> ControllerProfile {
        var profile = ControllerProfile(name: name)
        profile.schemaVersion = currentSchemaVersion
        profile.setAction(.keyboard(.init(key: .up)), for: .dpadUp)
        profile.setAction(.keyboard(.init(key: .down)), for: .dpadDown)
        profile.setAction(.keyboard(.init(key: .left)), for: .dpadLeft)
        profile.setAction(.keyboard(.init(key: .right)), for: .dpadRight)
        profile.setAction(.keyboard(.init(key: .enter)), for: .cross)
        profile.setAction(.keyboard(.init(key: .escape)), for: .circle)
        profile.setAction(.keyboard(.init(key: .tab)), for: .leftShoulder)
        profile.setAction(.keyboard(.init(key: .tab, modifiers: [.shift])), for: .leftTrigger)
        profile.setAction(.keyboard(.init(key: .space, modifiers: [.nvda])), for: .square)
        profile.setAction(.keyboard(.init(key: .n, modifiers: [.nvda])), for: .triangle)
        profile.setAction(.keyboard(.init(key: .pageUp)), for: .rightStickUp)
        profile.setAction(.keyboard(.init(key: .pageDown)), for: .rightStickDown)
        profile.setAction(.keyboard(.init(key: .home)), for: .rightStickLeft)
        profile.setAction(.keyboard(.init(key: .end)), for: .rightStickRight)
        profile.setAction(.keyboard(.init(key: .w, modifiers: [.control])), for: .rightShoulder)
        profile.setAction(.keyboard(.init(key: .f4, modifiers: [.alt])), for: .rightTrigger)
        profile.setAction(.keyboard(.init(key: .backspace)), for: .rightStickPress)
        profile.setAction(.layer(.init()), for: .options)
        profile.setAction(.quickNavigation(.toggle), for: .create)
        profile.setAction(.farRelay(.textMode), for: .touchpadPress)
        profile.setAction(.farRelay(.nextProfile), for: .home)
        var extended = ControllerLayerDefinition(
            id: ControllerLayerDefinition.extendedID,
            name: "Extended",
            bindings: ControllerInput.allCases.map { .init(sourceInput: $0, action: nil) }
        )
        extended.setAction(.keyboard(.init(key: .pageUp)), for: .dpadUp)
        extended.setAction(.keyboard(.init(key: .pageDown)), for: .dpadDown)
        extended.setAction(.keyboard(.init(key: .home)), for: .dpadLeft)
        extended.setAction(.keyboard(.init(key: .end)), for: .dpadRight)
        extended.setAction(.farRelay(.repeatLastQuickBar), for: .cross)
        extended.setAction(.keyboard(.init(key: .f4, modifiers: [.alt])), for: .circle)
        extended.setAction(.farRelay(.previousProfile), for: .home)
        profile.layers = [extended]
        profile.quickBar = QuickBarEntry.recommended
        profile.quickNavigationOrder = QuickNavigationCategory.defaultOrder
        return profile
    }

    func migratedToCurrentSchema() -> ControllerProfile? {
        guard schemaVersion <= Self.currentSchemaVersion,
              var normalized = normalizedBindingSlots() else { return nil }
        if normalized.schemaVersion == 1 && normalized.layers.isEmpty {
            normalized.layers = [
                .init(
                    id: ControllerLayerDefinition.extendedID,
                    name: "Extended",
                    bindings: ControllerInput.allCases.map { .init(sourceInput: $0, action: nil) }
                )
            ]
        }
        guard Set(normalized.quickBar.map(\.id)).count == normalized.quickBar.count,
              let rotorOrder = Self.normalizedQuickNavigationOrder(normalized.quickNavigationOrder) else {
            return nil
        }
        normalized.quickNavigationOrder = rotorOrder
        normalized.schemaVersion = Self.currentSchemaVersion
        return normalized
    }

    private static func normalizedQuickNavigationOrder(
        _ order: [QuickNavigationCategory]
    ) -> [QuickNavigationCategory]? {
        guard Set(order).count == order.count else { return nil }
        var normalized = order
        for category in QuickNavigationCategory.defaultOrder where !normalized.contains(category) {
            normalized.append(category)
        }
        return normalized
    }

    /// Older profile bytes can omit a controller input introduced by a later
    /// app build. Add only unassigned slots; duplicate source identifiers are
    /// ambiguous and are rejected rather than silently choosing one mapping.
    func normalizedBindingSlots() -> ControllerProfile? {
        guard Set(bindings.map(\.sourceInput)).count == bindings.count else { return nil }
        guard Set(layers.map(\.id)).count == layers.count else { return nil }
        var normalized = self
        for input in ControllerInput.allCases where normalized.bindings.contains(where: { $0.sourceInput == input }) == false {
            normalized.bindings.append(.init(sourceInput: input, action: nil))
        }
        for index in normalized.layers.indices {
            guard Set(normalized.layers[index].bindings.map(\.sourceInput)).count == normalized.layers[index].bindings.count else { return nil }
            for input in ControllerInput.allCases where normalized.layers[index].bindings.contains(where: { $0.sourceInput == input }) == false {
                normalized.layers[index].bindings.append(.init(sourceInput: input, action: nil))
            }
        }
        return normalized
    }
}

enum ControllerRecommendedLayout {
    /// Base bindings deliberately leave several controls free for personal
    /// shortcuts. The layer control is assigned separately so an existing user
    /// choice (for example R1) is never overwritten.
    static let base: [ControllerInput: ControllerAction] = [
        .dpadUp: .keyboard(.init(key: .up)),
        .dpadDown: .keyboard(.init(key: .down)),
        .dpadLeft: .keyboard(.init(key: .left)),
        .dpadRight: .keyboard(.init(key: .right)),
        .cross: .keyboard(.init(key: .enter)),
        .circle: .keyboard(.init(key: .escape)),
        .leftShoulder: .keyboard(.init(key: .tab)),
        .leftTrigger: .keyboard(.init(key: .tab, modifiers: [.shift])),
        .square: .keyboard(.init(key: .space, modifiers: [.nvda])),
        .triangle: .keyboard(.init(key: .n, modifiers: [.nvda])),
        .rightTrigger: .keyboard(.init(key: .f4, modifiers: [.alt])),
        .rightStickUp: .keyboard(.init(key: .pageUp)),
        .rightStickDown: .keyboard(.init(key: .pageDown)),
        .rightStickLeft: .keyboard(.init(key: .home)),
        .rightStickRight: .keyboard(.init(key: .end)),
        .rightStickPress: .keyboard(.init(key: .backspace)),
        .create: .quickNavigation(.toggle),
        .touchpadPress: .farRelay(.textMode),
        .home: .farRelay(.nextProfile)
    ]

    static let extended: [ControllerInput: ControllerAction] = [
        .dpadUp: .keyboard(.init(key: .pageUp)),
        .dpadDown: .keyboard(.init(key: .pageDown)),
        .dpadLeft: .keyboard(.init(key: .home)),
        .dpadRight: .keyboard(.init(key: .end)),
        .cross: .farRelay(.repeatLastQuickBar),
        .circle: .keyboard(.init(key: .f4, modifiers: [.alt])),
        .square: .keyboard(.init(key: .a, modifiers: [.control])),
        .triangle: .keyboard(.init(key: .delete)),
        .leftShoulder: .keyboard(.init(key: .tab, modifiers: [.alt])),
        .leftTrigger: .keyboard(.init(key: .tab, modifiers: [.shift, .alt])),
        .rightStickPress: .keyboard(.init(key: .backspace)),
        .home: .farRelay(.previousProfile)
    ]
}

enum ControllerProfileLoadResult: Equatable {
    case profile(ControllerProfile)
    case uninitialized
    case malformedOrUnsupported
}

struct ControllerProfileStore {
    let defaults: UserDefaults
    let key: String

    func load() -> ControllerProfileLoadResult {
        guard let data = defaults.data(forKey: key) else { return .uninitialized }
        guard let decoded = try? JSONDecoder().decode(ControllerProfile.self, from: data),
              let migrated = decoded.migratedToCurrentSchema() else {
            return .malformedOrUnsupported
        }
        return .profile(migrated)
    }

    func save(_ profile: ControllerProfile) {
        defaults.set(try? JSONEncoder().encode(profile), forKey: key)
    }
}

struct ControllerProfileLibrary: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var activeProfileID: UUID
    var profiles: [ControllerProfile]

    func normalized() -> ControllerProfileLibrary? {
        guard schemaVersion <= Self.currentSchemaVersion,
              !profiles.isEmpty,
              Set(profiles.map(\.id)).count == profiles.count else { return nil }
        var migratedProfiles: [ControllerProfile] = []
        migratedProfiles.reserveCapacity(profiles.count)
        for profile in profiles {
            guard let migrated = profile.migratedToCurrentSchema() else { return nil }
            migratedProfiles.append(migrated)
        }
        guard migratedProfiles.contains(where: { $0.id == activeProfileID }) else { return nil }
        return .init(
            schemaVersion: Self.currentSchemaVersion,
            activeProfileID: activeProfileID,
            profiles: migratedProfiles
        )
    }
}

enum ControllerProfileLibraryLoadResult: Equatable {
    case library(ControllerProfileLibrary)
    case uninitialized
    case malformedOrUnsupported
}

struct ControllerProfileLibraryStore {
    let defaults: UserDefaults
    let key: String

    func load() -> ControllerProfileLibraryLoadResult {
        guard let data = defaults.data(forKey: key) else { return .uninitialized }
        guard let decoded = try? JSONDecoder().decode(ControllerProfileLibrary.self, from: data),
              let normalized = decoded.normalized() else {
            return .malformedOrUnsupported
        }
        return .library(normalized)
    }

    func save(_ library: ControllerProfileLibrary) {
        defaults.set(try? JSONEncoder().encode(library), forKey: key)
    }
}

@Observable @MainActor
final class ControllerMappingSettings {
    private(set) var profiles: [ControllerProfile]
    private(set) var activeProfileID: UUID
    private(set) var editingProfileID: UUID
    private(set) var draftProfile: ControllerProfile

    private let libraryStore: ControllerProfileLibraryStore
    private let legacyStore: ControllerProfileStore

    /// The adapter releases any action it began before an edit or active
    /// profile switch is applied, so remapping can never strand a remote key.
    var willChangeActiveProfile: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard) {
        let newLibraryStore = ControllerProfileLibraryStore(
            defaults: defaults,
            key: "farrelay.controllerProfileLibrary.v1"
        )
        let newLegacyStore = ControllerProfileStore(
            defaults: defaults,
            key: "farrelay.controllerProfile.v1"
        )
        libraryStore = newLibraryStore
        legacyStore = newLegacyStore

        let library: ControllerProfileLibrary
        switch newLibraryStore.load() {
        case .library(let loaded):
            library = loaded
        case .uninitialized:
            let initialProfile: ControllerProfile
            switch newLegacyStore.load() {
            case .profile(let legacy):
                initialProfile = legacy
            case .uninitialized, .malformedOrUnsupported:
                // A malformed legacy record is deliberately left untouched.
                // The new library lives under a different key.
                initialProfile = .newDefault()
            }
            library = .init(activeProfileID: initialProfile.id, profiles: [initialProfile])
            newLibraryStore.save(library)
        case .malformedOrUnsupported:
            // Never overwrite malformed library bytes. Use a safe runtime
            // profile until the user explicitly saves a later valid edit.
            let fallback = ControllerProfile.newDefault()
            library = .init(activeProfileID: fallback.id, profiles: [fallback])
        }

        profiles = library.profiles
        activeProfileID = library.activeProfileID
        editingProfileID = library.activeProfileID
        draftProfile = library.profiles.first(where: { $0.id == library.activeProfileID })!
    }

    var activeProfile: ControllerProfile {
        profiles.first(where: { $0.id == activeProfileID })!
    }

    var hasUnsavedChanges: Bool {
        guard let saved = profiles.first(where: { $0.id == editingProfileID }) else { return true }
        return draftProfile != saved
    }

    @discardableResult
    func beginEditing(profileID: UUID? = nil) -> Bool {
        let targetID = profileID ?? activeProfileID
        guard let profile = profiles.first(where: { $0.id == targetID }) else { return false }
        if hasUnsavedChanges && editingProfileID != targetID { return false }
        if editingProfileID == targetID && hasUnsavedChanges { return true }
        editingProfileID = targetID
        draftProfile = profile
        return true
    }

    func setAction(_ action: ControllerAction?, for input: ControllerInput) {
        draftProfile.setAction(action, for: input)
    }

    func setAction(_ action: ControllerAction?, for input: ControllerInput, layerID: String?) {
        guard let layerID else {
            setAction(action, for: input)
            return
        }
        guard let index = draftProfile.layers.firstIndex(where: { $0.id == layerID }) else { return }
        draftProfile.layers[index].setAction(action, for: input)
    }

    func renameDraftProfile(_ name: String) {
        draftProfile.name = name
    }

    func setQuickNavigationAutoExitAfterAction(_ enabled: Bool) {
        draftProfile.quickNavigationAutoExitAfterAction = enabled
    }

    func setQuickBarAction(_ action: ControllerAction?, entryID: UUID) {
        guard let index = draftProfile.quickBar.firstIndex(where: { $0.id == entryID }) else { return }
        draftProfile.quickBar[index].action = action
    }

    @discardableResult
    func addQuickBarEntry(action: ControllerAction? = nil) -> UUID {
        let entry = QuickBarEntry(action: action)
        draftProfile.quickBar.append(entry)
        return entry.id
    }

    func deleteQuickBarEntries(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where draftProfile.quickBar.indices.contains(index) {
            draftProfile.quickBar.remove(at: index)
        }
    }

    func moveQuickBarEntries(from offsets: IndexSet, to destination: Int) {
        moveItems(in: &draftProfile.quickBar, from: offsets, to: destination)
    }

    @discardableResult
    func moveQuickBarEntry(id: UUID, direction: Int) -> Int? {
        guard let index = draftProfile.quickBar.firstIndex(where: { $0.id == id }),
              direction != 0 else { return nil }
        let destination = index + (direction < 0 ? -1 : 1)
        guard draftProfile.quickBar.indices.contains(destination) else { return nil }
        draftProfile.quickBar.swapAt(index, destination)
        return destination
    }

    @discardableResult
    func moveQuickBarEntryToStart(id: UUID) -> Int? {
        guard let index = draftProfile.quickBar.firstIndex(where: { $0.id == id }),
              index > 0 else { return nil }
        let entry = draftProfile.quickBar.remove(at: index)
        draftProfile.quickBar.insert(entry, at: 0)
        return 0
    }

    @discardableResult
    func moveQuickBarEntryToEnd(id: UUID) -> Int? {
        guard let index = draftProfile.quickBar.firstIndex(where: { $0.id == id }),
              index < draftProfile.quickBar.count - 1 else { return nil }
        let destination = draftProfile.quickBar.count - 1
        let entry = draftProfile.quickBar.remove(at: index)
        draftProfile.quickBar.append(entry)
        return destination
    }

    func moveQuickNavigationCategories(from offsets: IndexSet, to destination: Int) {
        moveItems(in: &draftProfile.quickNavigationOrder, from: offsets, to: destination)
    }

    @discardableResult
    func moveQuickNavigationCategory(_ category: QuickNavigationCategory, direction: Int) -> Int? {
        guard let index = draftProfile.quickNavigationOrder.firstIndex(of: category),
              direction != 0 else { return nil }
        let destination = index + (direction < 0 ? -1 : 1)
        guard draftProfile.quickNavigationOrder.indices.contains(destination) else { return nil }
        draftProfile.quickNavigationOrder.swapAt(index, destination)
        return destination
    }

    @discardableResult
    func moveQuickNavigationCategoryToStart(_ category: QuickNavigationCategory) -> Int? {
        guard let index = draftProfile.quickNavigationOrder.firstIndex(of: category),
              index > 0 else { return nil }
        draftProfile.quickNavigationOrder.remove(at: index)
        draftProfile.quickNavigationOrder.insert(category, at: 0)
        return 0
    }

    @discardableResult
    func moveQuickNavigationCategoryToEnd(_ category: QuickNavigationCategory) -> Int? {
        guard let index = draftProfile.quickNavigationOrder.firstIndex(of: category),
              index < draftProfile.quickNavigationOrder.count - 1 else { return nil }
        let destination = draftProfile.quickNavigationOrder.count - 1
        draftProfile.quickNavigationOrder.remove(at: index)
        draftProfile.quickNavigationOrder.append(category)
        return destination
    }

    func restoreRecommendedQuickNavigationOrder() {
        draftProfile.quickNavigationOrder = QuickNavigationCategory.defaultOrder
    }

    func restoreRecommendedQuickBar() {
        draftProfile.quickBar = QuickBarEntry.recommended
    }

    /// Fills only currently unassigned slots. Existing user choices are never
    /// replaced. If no layer-control binding exists, R1 is preferred; Options
    /// is used only as a fallback when R1 is already occupied.
    @discardableResult
    func fillUnassignedWithRecommendedLayout() -> Int {
        var changes = 0

        for (input, action) in ControllerRecommendedLayout.base
        where draftProfile.action(for: input) == nil {
            draftProfile.setAction(action, for: input)
            changes += 1
        }

        let hasLayerControl = draftProfile.bindings.contains { binding in
            guard let action = binding.action else { return false }
            if case .layer = action { return true }
            return false
        }
        if !hasLayerControl {
            if draftProfile.action(for: .rightShoulder) == nil {
                draftProfile.setAction(.layer(.init()), for: .rightShoulder)
                changes += 1
            } else if draftProfile.action(for: .options) == nil {
                draftProfile.setAction(.layer(.init()), for: .options)
                changes += 1
            }
        }

        if draftProfile.layers.contains(where: { $0.id == ControllerLayerDefinition.extendedID }) == false {
            draftProfile.layers.append(.init(
                id: ControllerLayerDefinition.extendedID,
                name: "Extended",
                bindings: ControllerInput.allCases.map { .init(sourceInput: $0, action: nil) }
            ))
        }

        guard let extendedIndex = draftProfile.layers.firstIndex(where: { $0.id == ControllerLayerDefinition.extendedID }) else {
            return changes
        }
        for (input, action) in ControllerRecommendedLayout.extended
        where draftProfile.layers[extendedIndex].action(for: input) == nil {
            draftProfile.layers[extendedIndex].setAction(action, for: input)
            changes += 1
        }
        return changes
    }

    func saveDraft() {
        guard hasUnsavedChanges,
              let index = profiles.firstIndex(where: { $0.id == editingProfileID }) else { return }
        if editingProfileID == activeProfileID { willChangeActiveProfile?() }
        profiles[index] = draftProfile
        persistLibrary()
    }

    func discardDraft() {
        guard let saved = profiles.first(where: { $0.id == editingProfileID }) else { return }
        draftProfile = saved
    }

    @discardableResult
    func createProfile(name: String? = nil) -> UUID {
        let defaultName = "Profile \(profiles.count + 1)"
        let profile = ControllerProfile.blank(name: name ?? defaultName)
        profiles.append(profile)
        persistLibrary()
        return profile.id
    }

    /// Profile creation from the editor must never leave the new row disabled
    /// behind an older unsaved draft. Commit that draft first, then attach the
    /// editor to the newly created profile.
    @discardableResult
    func createProfileForEditing(name: String? = nil) -> UUID {
        if hasUnsavedChanges { saveDraft() }
        let id = createProfile(name: name)
        _ = beginEditing(profileID: id)
        return id
    }

    func portableManifest(
        for profileID: UUID
    ) -> FarRelayControllerProfileManifest? {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            return nil
        }
        return FarRelayControllerProfileManifest(profile: profile)
    }

    func exportPortableProfileData(profileID: UUID) throws -> Data {
        guard let manifest = portableManifest(for: profileID) else {
            throw FarRelayProfileFileError.invalidProfile(
                "The controller profile no longer exists."
            )
        }
        return try FarRelayProfileCodec.encode(manifest)
    }

    @discardableResult
    func importPortableProfileData(_ data: Data) throws -> UUID {
        let manifest = try FarRelayProfileCodec.decode(data)
        return try importPortableProfile(manifest)
    }

    @discardableResult
    func importPortableProfile(
        _ manifest: FarRelayControllerProfileManifest
    ) throws -> UUID {
        var imported = try manifest.makeControllerProfile()
        imported.name = uniqueProfileName(imported.name)
        profiles.append(imported)
        persistLibrary()
        return imported.id
    }

    @discardableResult
    func deleteProfile(id: UUID) -> Bool {
        guard profiles.count > 1,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return false }

        let deletingActive = id == activeProfileID
        if deletingActive { willChangeActiveProfile?() }
        profiles.remove(at: index)

        if deletingActive {
            activeProfileID = profiles[min(index, profiles.count - 1)].id
        }
        if editingProfileID == id {
            editingProfileID = activeProfileID
            draftProfile = activeProfile
        }
        persistLibrary()
        return true
    }

    func moveProfiles(from offsets: IndexSet, to destination: Int) {
        moveItems(in: &profiles, from: offsets, to: destination)
        persistLibrary()
    }

    @discardableResult
    func activateProfile(id: UUID) -> String? {
        guard id != activeProfileID,
              let profile = profiles.first(where: { $0.id == id }) else {
            return profiles.first(where: { $0.id == id })?.name
        }
        willChangeActiveProfile?()
        activeProfileID = id
        persistLibrary()
        return profile.name
    }

    @discardableResult
    func activateNextProfile() -> String? {
        guard profiles.count > 1,
              let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else {
            return activeProfile.name
        }
        return activateProfile(id: profiles[(index + 1) % profiles.count].id)
    }

    @discardableResult
    func activatePreviousProfile() -> String? {
        guard profiles.count > 1,
              let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else {
            return activeProfile.name
        }
        return activateProfile(id: profiles[(index - 1 + profiles.count) % profiles.count].id)
    }

    private func uniqueProfileName(_ requestedName: String) -> String {
        guard profiles.contains(where: { $0.name == requestedName }) else {
            return requestedName
        }

        var suffix = 2
        while profiles.contains(where: { $0.name == "\(requestedName) (\(suffix))" }) {
            suffix += 1
        }
        return "\(requestedName) (\(suffix))"
    }

    private func persistLibrary() {
        libraryStore.save(.init(activeProfileID: activeProfileID, profiles: profiles))
    }

    private func moveItems<T>(in items: inout [T], from offsets: IndexSet, to destination: Int) {
        let validOffsets = offsets.filter { items.indices.contains($0) }
        guard !validOffsets.isEmpty else { return }
        let moving = validOffsets.map { items[$0] }
        for index in validOffsets.sorted(by: >) {
            items.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertion = max(0, min(items.count, destination - removedBeforeDestination))
        items.insert(contentsOf: moving, at: insertion)
    }
}
