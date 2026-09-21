import SwiftUI

/// A standard list-based editor so every mapping remains reachable with VoiceOver.
struct ControllerMappingView: View {
    @Environment(ControllerMappingSettings.self) private var mappings
    @Environment(DualSenseControllerAdapter.self) private var controllerAdapter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("How it works") {
                Text("Base mappings are always active. Extended mappings are used through any button assigned to Layer: hold it for momentary Extended, tap it for one Extended action, or double-tap it to lock Extended until you press the Layer button again.")
                Text("NVDA Quick Navigation uses D-pad left or right as the rotor to change sections: Quick Bar, Headings, Links, Form controls, Edit fields, Buttons, Landmarks, Tables, or Lists. Right-stick up or down moves within the selected section. Cross runs the selected Quick Bar action locally without sending Enter, or sends Enter to activate the current remote item in the other sections.")
            }

            Section("Recommended layout") {
                Button("Fill Unassigned with Recommended Layout") {
                    let count = mappings.fillUnassignedWithRecommendedLayout()
                    let message = count == 0
                        ? "Recommended layout is already filled."
                        : "\(count) unassigned controller mappings filled. Review them, then choose Save Mappings."
                    AccessibilityNotification.Announcement(message).post()
                }
                .accessibilityHint("Adds the recommended Base and Extended mappings without replacing any mapping you already configured.")
                Text("This never overwrites an existing mapping. If no Layer button exists, R1 is preferred and Options is used only if R1 is already occupied.")
                    .foregroundStyle(.secondary)
            }

            mappingSection(title: "Base", layerID: nil)
            ForEach(mappings.draftProfile.layers) { layer in
                mappingSection(title: layer.name, layerID: layer.id)
            }

            if mappings.hasUnsavedChanges {
                Section("Unsaved changes") {
                    Button("Discard Unsaved Changes", role: .destructive) {
                        mappings.discardDraft()
                    }
                }
            }

            if controllerAdapter.controllerHasRemappedElements {
                Section("Controller") {
                    Text("This controller follows its current iOS button remapping.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Controller Mapping")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save Mappings") {
                    mappings.saveDraft()
                    dismiss()
                    DispatchQueue.main.async {
                        AccessibilityNotification.Announcement(
                            "Controller mappings saved. Settings."
                        ).post()
                    }
                }
                .accessibilityHint("Saves every edited controller binding and returns to Settings.")
            }
        }
        .onAppear { mappings.beginEditing() }
    }

    private func summary(for action: ControllerAction?) -> String {
        switch action {
        case nil: return "Unassigned"
        case .keyboard(let keyboard):
            let modifiers = keyboard.modifiers.map(\.label).sorted()
            return (modifiers + [keyboard.key.label]).joined(separator: "+")
        case .layer(let layer): return "\(layer.layerID.capitalized) layer"
        case .quickNavigation: return "NVDA Quick Navigation"
        case .farRelay(.textMode): return "Text Mode"
        }
    }

    private func availability(for input: ControllerInput) -> String {
        guard controllerAdapter.connectedControllerName != nil else {
            return "No controller connected — mapping can still be edited"
        }
        return controllerAdapter.availableInputs.contains(input)
            ? "Available on this controller"
            : "Unavailable on this controller"
    }

    @ViewBuilder
    private func mappingSection(title: String, layerID: String?) -> some View {
        Section(title) {
            ForEach(ControllerInput.allCases) { input in
                NavigationLink {
                    ControllerBindingEditor(input: input, layerID: layerID)
                } label: {
                    VStack(alignment: .leading) {
                        Text(input.label)
                        Text(summary(for: mappings.draftProfile.action(for: input, layerID: layerID)))
                            .foregroundStyle(.secondary)
                        if layerID == nil {
                            Text(availability(for: input))
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

enum ControllerMappingActionType: String, CaseIterable, Identifiable {
    case unassigned = "Unassigned", keyboard = "Keyboard", layer = "Layer"
    case quickNavigation = "NVDA Quick Navigation", farRelay = "Text Mode"
    var id: String { rawValue }
}

struct ControllerBindingEditorState: Equatable {
    var type: ControllerMappingActionType {
        didSet {
            guard type != .keyboard else { return }
            key = nil
            modifiers = []
        }
    }
    var key: WindowsKeyboardKey? {
        didSet {
            if key != nil, type == .unassigned { type = .keyboard }
        }
    }
    var modifiers: Set<ControllerKeyboardModifier>

    init(action: ControllerAction?) {
        if case .keyboard(let keyboard) = action {
            type = .keyboard
            key = keyboard.key
            modifiers = keyboard.modifiers
        } else if case .layer = action {
            type = .layer; key = nil; modifiers = []
        } else if case .quickNavigation = action {
            type = .quickNavigation; key = nil; modifiers = []
        } else if case .farRelay = action {
            type = .farRelay; key = nil; modifiers = []
        } else {
            type = .unassigned
            key = nil
            modifiers = []
        }
    }

    var action: ControllerAction? {
        switch type {
        case .unassigned: return nil
        case .keyboard:
            guard let key else { return nil }
            return .keyboard(.init(key: key, modifiers: modifiers))
        case .layer: return .layer(.init())
        case .quickNavigation: return .quickNavigation(.toggle)
        case .farRelay: return .farRelay(.textMode)
        }
    }
}

struct ControllerBindingEditor: View {
    let input: ControllerInput
    let layerID: String?
    @Environment(ControllerMappingSettings.self) private var mappings
    @State private var editorState = ControllerBindingEditorState(action: nil)

    var body: some View {
        Form {
            Section("Controller input") { Text(input.label) }
            Section("Action") {
                Picker("Action Type", selection: $editorState.type) {
                    ForEach(ControllerMappingActionType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
            }
            if editorState.type == .keyboard {
                Section("Keyboard") {
                    Picker("Primary key", selection: $editorState.key) {
                        Text("Unassigned").tag(WindowsKeyboardKey?.none)
                        ForEach(WindowsKeyboardKey.allCases) { key in
                            Text(key.label).tag(Optional(key))
                        }
                    }
                    ForEach(ControllerKeyboardModifier.allCases) { modifier in
                        Toggle(modifier.label, isOn: modifierBinding(modifier))
                            .disabled(editorState.key == nil)
                    }
                }
            }
            if editorState.type == .layer {
                Section("Layer") {
                    Text("Extended")
                    Text("Hold this button for momentary Extended, tap it for one Extended action, or double-tap it to lock Extended until you press the Layer button again.")
                        .foregroundStyle(.secondary)
                }
            }
            if editorState.type == .quickNavigation {
                Section("NVDA Quick Navigation") {
                    Text("Rotor-style navigation with D-pad left or right changing sections and right-stick up or down moving within the selected section. Quick Bar is the first section. Cross executes its highlighted Quick Bar action without sending Enter, while Cross sends Enter in Headings, Links, and the other Browse Mode sections. Circle or this same Quick Navigation button exits.")
                        .foregroundStyle(.secondary)
                    Text("This version uses NVDA Browse Mode keyboard shortcuts, so use it while NVDA is in Browse Mode.")
                        .foregroundStyle(.secondary)
                }
            }
            if editorState.type == .farRelay {
                Section("Text Mode") {
                    Text("Opens the local iPhone text editor for VoiceOver Braille Screen Input and mirrors supported text live to the remote field.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Clear Mapping", role: .destructive) {
                    editorState = ControllerBindingEditorState(action: nil)
                }
            }
        }
        .navigationTitle(input.label)
        .onAppear {
            editorState = ControllerBindingEditorState(
                action: mappings.draftProfile.action(for: input, layerID: layerID)
            )
        }
        .onChange(of: editorState) { _, newValue in
            mappings.setAction(newValue.action, for: input, layerID: layerID)
        }
    }

    private func modifierBinding(_ modifier: ControllerKeyboardModifier) -> Binding<Bool> {
        Binding(
            get: { editorState.modifiers.contains(modifier) },
            set: { selected in
                if selected {
                    editorState.modifiers.insert(modifier)
                } else {
                    editorState.modifiers.remove(modifier)
                }
            }
        )
    }
}
