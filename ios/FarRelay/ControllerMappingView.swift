import SwiftUI

/// A standard list-based editor so every mapping remains reachable with VoiceOver.
struct ControllerMappingView: View {
    @Environment(ControllerMappingSettings.self) private var mappings
    @Environment(DualSenseControllerAdapter.self) private var controllerAdapter

    var body: some View {
        List {
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
                    AccessibilityNotification.Announcement(
                        "Controller mappings saved."
                    ).post()
                }
                .disabled(!mappings.hasUnsavedChanges)
                .accessibilityHint("Saves every edited controller binding.")
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
        case .quickNavigation: return "Quick Navigation"
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
    case quickNavigation = "Quick Navigation", farRelay = "Text Mode"
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
                Section("Layer") { Text("Extended") }
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
