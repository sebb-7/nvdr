import Foundation

enum FarRelayProfileFileError: Error, Equatable, LocalizedError {
    case malformedFile
    case unsupportedFormat(String)
    case unsupportedVersion(Int)
    case unsupportedController(String)
    case duplicateBinding(String)
    case duplicateLayer(String)
    case duplicateRotorItem(String)
    case unknownInput(String)
    case unknownKey(String)
    case unknownModifier(String)
    case unknownRotorItem(String)
    case unsupportedAction(String)
    case invalidProfile(String)

    var errorDescription: String? {
        switch self {
        case .malformedFile:
            return "This is not a valid FarRelay controller profile."
        case .unsupportedFormat(let format):
            return "Unsupported FarRelay profile format: \(format)."
        case .unsupportedVersion(let version):
            return "This .fr profile uses version \(version), which this FarRelay build does not support."
        case .unsupportedController(let controller):
            return "This profile targets an unsupported controller: \(controller)."
        case .duplicateBinding(let input):
            return "The profile assigns \(input) more than once in the same mapping layer."
        case .duplicateLayer(let id):
            return "The profile contains more than one layer named \(id)."
        case .duplicateRotorItem(let item):
            return "The rotor contains \(item) more than once."
        case .unknownInput(let input):
            return "The profile references an unknown controller input: \(input)."
        case .unknownKey(let key):
            return "The profile references an unknown keyboard key: \(key)."
        case .unknownModifier(let modifier):
            return "The profile references an unknown keyboard modifier: \(modifier)."
        case .unknownRotorItem(let item):
            return "The profile references an unknown rotor item: \(item)."
        case .unsupportedAction(let action):
            return "The profile references an unsupported action: \(action)."
        case .invalidProfile(let reason):
            return reason
        }
    }
}

struct FarRelayPortableBinding: Codable, Equatable, Sendable {
    var input: String
    var action: FarRelayPortableAction?
}

struct FarRelayPortableLayer: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var mappings: [FarRelayPortableBinding]
}

struct FarRelayPortableAction: Codable, Equatable, Sendable {
    static let keyboardType = "keyboard"
    static let holdModifierType = "hold-modifier"
    static let layerType = "layer"
    static let quickNavigationType = "quick-navigation"
    static let farRelayType = "farrelay"

    var type: String
    var key: String?
    var modifiers: [String]?
    var tapKey: String?
    var layerID: String?
    var command: String?

    init(
        type: String,
        key: String? = nil,
        modifiers: [String]? = nil,
        tapKey: String? = nil,
        layerID: String? = nil,
        command: String? = nil
    ) {
        self.type = type
        self.key = key
        self.modifiers = modifiers
        self.tapKey = tapKey
        self.layerID = layerID
        self.command = command
    }

    init(_ action: ControllerAction) {
        switch action {
        case .keyboard(let keyboard):
            self.init(
                type: Self.keyboardType,
                key: keyboard.key.rawValue,
                modifiers: keyboard.modifiers.map(\.rawValue).sorted()
            )
        case .stickyModifier(let held):
            self.init(
                type: Self.holdModifierType,
                modifiers: held.modifiers.map(\.rawValue).sorted(),
                tapKey: held.tapKey?.rawValue
            )
        case .layer(let layer):
            self.init(type: Self.layerType, layerID: layer.layerID)
        case .quickNavigation:
            self.init(type: Self.quickNavigationType, command: "toggle")
        case .farRelay(let action):
            self.init(type: Self.farRelayType, command: Self.portableIdentifier(for: action))
        }
    }

    func controllerAction() throws -> ControllerAction {
        switch type {
        case Self.keyboardType:
            guard let key else {
                throw FarRelayProfileFileError.invalidProfile(
                    "A keyboard action is missing its key."
                )
            }
            guard let decodedKey = WindowsKeyboardKey(rawValue: key) else {
                throw FarRelayProfileFileError.unknownKey(key)
            }
            return .keyboard(
                .init(key: decodedKey, modifiers: try decodedModifiers())
            )

        case Self.holdModifierType:
            let decoded = try decodedModifiers()
            let decodedTapKey: WindowsKeyboardKey?
            if let tapKey {
                guard let value = WindowsKeyboardKey(rawValue: tapKey) else {
                    throw FarRelayProfileFileError.unknownKey(tapKey)
                }
                decodedTapKey = value
            } else {
                decodedTapKey = nil
            }
            let held = ControllerStickyModifierAction(
                modifiers: decoded,
                tapKey: decodedTapKey
            )
            guard held.isValid else {
                throw FarRelayProfileFileError.invalidProfile(
                    "A Hold Modifier action must contain one to \(ControllerStickyModifierAction.maximumHeldModifiers) unique modifiers."
                )
            }
            return .stickyModifier(held)

        case Self.layerType:
            guard let layerID, !layerID.isEmpty else {
                throw FarRelayProfileFileError.invalidProfile(
                    "A layer action is missing its layer identifier."
                )
            }
            return .layer(.init(layerID: layerID))

        case Self.quickNavigationType:
            guard command == nil || command == "toggle" else {
                throw FarRelayProfileFileError.unsupportedAction(
                    "\(type).\(command ?? "")"
                )
            }
            return .quickNavigation(.toggle)

        case Self.farRelayType:
            guard let command,
                  let action = Self.farRelayAction(for: command) else {
                throw FarRelayProfileFileError.unsupportedAction(
                    "\(type).\(command ?? "missing-command")"
                )
            }
            return .farRelay(action)

        default:
            throw FarRelayProfileFileError.unsupportedAction(type)
        }
    }

    private func decodedModifiers() throws -> Set<ControllerKeyboardModifier> {
        let requested = modifiers ?? []
        let unique = Set(requested)
        guard unique.count == requested.count else {
            throw FarRelayProfileFileError.invalidProfile(
                "A keyboard action repeats the same modifier."
            )
        }

        var decoded: Set<ControllerKeyboardModifier> = []
        for raw in requested {
            guard let modifier = ControllerKeyboardModifier(rawValue: raw) else {
                throw FarRelayProfileFileError.unknownModifier(raw)
            }
            decoded.insert(modifier)
        }
        return decoded
    }

    private static func portableIdentifier(
        for action: FarRelayControllerAction
    ) -> String {
        switch action {
        case .textMode: "text-mode"
        case .quickCommandMode: "quick-command-mode"
        case .repeatLastQuickBar: "repeat-last-quick-bar"
        case .repeatLastQuickCommand: "repeat-last-command"
        case .nextProfile: "next-profile"
        case .previousProfile: "previous-profile"
        }
    }

    private static func farRelayAction(
        for identifier: String
    ) -> FarRelayControllerAction? {
        switch identifier {
        case "text-mode": .textMode
        case "quick-command-mode": .quickCommandMode
        case "repeat-last-quick-bar": .repeatLastQuickBar
        case "repeat-last-command": .repeatLastQuickCommand
        case "next-profile": .nextProfile
        case "previous-profile": .previousProfile
        default: nil
        }
    }
}

struct FarRelayPortableControllerProfile: Codable, Equatable, Sendable {
    var name: String
    var controller: String
    var mappings: [FarRelayPortableBinding]
    var layers: [FarRelayPortableLayer]
    var actionBar: [FarRelayPortableAction?]
    var rotor: [String]
    var quickNavigationAutoExitAfterAction: Bool?
}

struct FarRelayControllerProfileManifest: Codable, Equatable, Sendable {
    static let formatIdentifier = "farrelay.controller-profile"
    static let currentVersion = 1

    var format: String
    var version: Int
    var profile: FarRelayPortableControllerProfile

    init(profile: ControllerProfile) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.profile = .init(
            name: profile.name,
            controller: "dualsense",
            mappings: ControllerInput.allCases.map { input in
                .init(
                    input: input.rawValue,
                    action: profile.action(for: input).map(FarRelayPortableAction.init)
                )
            },
            layers: profile.layers.map { layer in
                .init(
                    id: layer.id,
                    name: layer.name,
                    mappings: ControllerInput.allCases.map { input in
                        .init(
                            input: input.rawValue,
                            action: layer.action(for: input).map(FarRelayPortableAction.init)
                        )
                    }
                )
            },
            actionBar: profile.quickBar.map { entry in
                entry.action.map(FarRelayPortableAction.init)
            },
            rotor: profile.quickNavigationOrder.map(Self.portableRotorIdentifier),
            quickNavigationAutoExitAfterAction: profile.quickNavigationAutoExitAfterAction
        )
    }

    var importSummary: String {
        let assignedBase = profile.mappings.filter { $0.action != nil }.count
        let assignedLayers = profile.layers.reduce(into: 0) { count, layer in
            count += layer.mappings.filter { $0.action != nil }.count
        }
        let assignedActionBar = profile.actionBar.filter { $0 != nil }.count
        return """
        \(profile.name)
        Controller: DualSense
        Mappings: \(assignedBase + assignedLayers)
        Layers: \(profile.layers.count)
        Action Bar: \(assignedActionBar) actions
        Rotor: \(profile.rotor.count) sections
        Exit Quick Navigation After Action: \((profile.quickNavigationAutoExitAfterAction ?? true) ? "On" : "Off")
        """
    }

    func makeControllerProfile(id: UUID = UUID()) throws -> ControllerProfile {
        guard format == Self.formatIdentifier else {
            throw FarRelayProfileFileError.unsupportedFormat(format)
        }
        guard version == Self.currentVersion else {
            throw FarRelayProfileFileError.unsupportedVersion(version)
        }

        let normalizedController = profile.controller
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard normalizedController == "dualsense" else {
            throw FarRelayProfileFileError.unsupportedController(profile.controller)
        }

        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw FarRelayProfileFileError.invalidProfile(
                "The controller profile needs a name."
            )
        }
        guard name.count <= 120 else {
            throw FarRelayProfileFileError.invalidProfile(
                "The controller profile name is too long."
            )
        }

        var layerIDs: Set<String> = []
        var layers: [ControllerLayerDefinition] = []
        for portableLayer in profile.layers {
            let layerID = portableLayer.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !layerID.isEmpty else {
                throw FarRelayProfileFileError.invalidProfile(
                    "A controller layer is missing its identifier."
                )
            }
            guard layerIDs.insert(layerID).inserted else {
                throw FarRelayProfileFileError.duplicateLayer(layerID)
            }
            let layerName = portableLayer.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !layerName.isEmpty else {
                throw FarRelayProfileFileError.invalidProfile(
                    "Layer \(layerID) needs a display name."
                )
            }
            layers.append(
                .init(
                    id: layerID,
                    name: layerName,
                    bindings: try convertedBindings(
                        portableLayer.mappings,
                        context: "layer \(layerID)"
                    )
                )
            )
        }

        let baseBindings = try convertedBindings(profile.mappings, context: "Base")
        try validateLayerTargets(in: baseBindings, knownLayerIDs: layerIDs)
        for layer in layers {
            try validateLayerTargets(in: layer.bindings, knownLayerIDs: layerIDs)
        }

        var actionBar: [QuickBarEntry] = []
        actionBar.reserveCapacity(profile.actionBar.count)
        for (index, portableAction) in profile.actionBar.enumerated() {
            let action = try portableAction?.controllerAction()
            if let action, !action.isAllowedInQuickBar {
                throw FarRelayProfileFileError.invalidProfile(
                    "Action Bar item \(index + 1) uses an action that is not allowed in the Action Bar."
                )
            }
            actionBar.append(.init(action: action))
        }

        let rotor = try normalizedRotor(profile.rotor)

        return ControllerProfile(
            schemaVersion: ControllerProfile.currentSchemaVersion,
            id: id,
            name: name,
            controller: .dualSense,
            bindings: baseBindings,
            layers: layers,
            quickBar: actionBar,
            quickNavigationOrder: rotor,
            quickNavigationAutoExitAfterAction: profile.quickNavigationAutoExitAfterAction ?? true
        )
    }

    private func convertedBindings(
        _ portableBindings: [FarRelayPortableBinding],
        context: String
    ) throws -> [ControllerBinding] {
        var seen: Set<String> = []
        var converted = ControllerInput.allCases.map {
            ControllerBinding(sourceInput: $0, action: nil)
        }

        for binding in portableBindings {
            guard seen.insert(binding.input).inserted else {
                throw FarRelayProfileFileError.duplicateBinding(
                    "\(context): \(binding.input)"
                )
            }
            guard let input = ControllerInput(rawValue: binding.input) else {
                throw FarRelayProfileFileError.unknownInput(binding.input)
            }
            let action = try binding.action?.controllerAction()
            guard let index = converted.firstIndex(where: { $0.sourceInput == input }) else {
                throw FarRelayProfileFileError.unknownInput(binding.input)
            }
            converted[index].action = action
        }

        return converted
    }

    private func validateLayerTargets(
        in bindings: [ControllerBinding],
        knownLayerIDs: Set<String>
    ) throws {
        for binding in bindings {
            guard case .layer(let layer)? = binding.action else { continue }
            guard knownLayerIDs.contains(layer.layerID) else {
                throw FarRelayProfileFileError.invalidProfile(
                    "The \(binding.sourceInput.rawValue) mapping references missing layer \(layer.layerID)."
                )
            }
        }
    }

    private func normalizedRotor(
        _ requested: [String]
    ) throws -> [QuickNavigationCategory] {
        var seen: Set<QuickNavigationCategory> = []
        var result: [QuickNavigationCategory] = []

        for identifier in requested {
            guard let category = Self.rotorCategory(for: identifier) else {
                throw FarRelayProfileFileError.unknownRotorItem(identifier)
            }
            guard seen.insert(category).inserted else {
                throw FarRelayProfileFileError.duplicateRotorItem(identifier)
            }
            result.append(category)
        }

        for category in QuickNavigationCategory.defaultOrder where !seen.contains(category) {
            result.append(category)
        }
        return result
    }

    private static func portableRotorIdentifier(
        _ category: QuickNavigationCategory
    ) -> String {
        switch category {
        case .quickBar: "action-bar"
        case .profiles: "profiles"
        case .editing: "editing"
        case .headings: "headings"
        case .links: "links"
        case .formControls: "form-controls"
        case .editFields: "edit-fields"
        case .buttons: "buttons"
        case .landmarks: "landmarks"
        case .tables: "tables"
        case .lists: "lists"
        }
    }

    private static func rotorCategory(
        for identifier: String
    ) -> QuickNavigationCategory? {
        switch identifier {
        case "action-bar", "quick-bar": .quickBar
        case "profiles": .profiles
        case "editing": .editing
        case "headings": .headings
        case "links": .links
        case "form-controls": .formControls
        case "edit-fields": .editFields
        case "buttons": .buttons
        case "landmarks": .landmarks
        case "tables": .tables
        case "lists": .lists
        default: nil
        }
    }
}

enum FarRelayProfileCodec {
    static func decode(_ data: Data) throws -> FarRelayControllerProfileManifest {
        let manifest: FarRelayControllerProfileManifest
        do {
            manifest = try JSONDecoder().decode(
                FarRelayControllerProfileManifest.self,
                from: data
            )
        } catch {
            throw FarRelayProfileFileError.malformedFile
        }

        _ = try manifest.makeControllerProfile()
        return manifest
    }

    static func encode(
        _ manifest: FarRelayControllerProfileManifest
    ) throws -> Data {
        _ = try manifest.makeControllerProfile()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }
}
