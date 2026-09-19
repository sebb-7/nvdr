import SwiftUI

/// A standard list-based editor so every mapping remains reachable with VoiceOver.
struct ControllerMappingView: View {
    @Environment(ControllerMappingSettings.self) private var mappings
    @Environment(DualSenseControllerAdapter.self) private var controllerAdapter

    var body: some View {
        List {
            ForEach(ControllerInput.allCases) { input in
                NavigationLink {
                    ControllerBindingEditor(input: input)
                } label: {
                    VStack(alignment: .leading) {
                        Text(input.label)
                        Text(summary(for: mappings.draftProfile.action(for: input)))
                            .foregroundStyle(.secondary)
                        Text(availability(for: input))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                }
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
        guard case .keyboard(let keyboard) = action else { return "Unassigned" }
        let modifiers = keyboard.modifiers.map(\.label).sorted()
        return (modifiers + [keyboard.key.label]).joined(separator: "+")
    }

    private func availability(for input: ControllerInput) -> String {
        guard controllerAdapter.connectedControllerName != nil else {
            return "No controller connected — mapping can still be edited"
        }
        return controllerAdapter.availableInputs.contains(input)
            ? "Available on this controller"
            : "Unavailable on this controller"
    }
}

struct ControllerBindingEditorState: Equatable {
    var key: WindowsKeyboardKey?
    var modifiers: Set<ControllerKeyboardModifier>

    init(action: ControllerAction?) {
        if case .keyboard(let keyboard) = action {
            key = keyboard.key
            modifiers = keyboard.modifiers
        } else {
            key = nil
            modifiers = []
        }
    }

    var action: ControllerAction? {
        guard let key else { return nil }
        return .keyboard(.init(key: key, modifiers: modifiers))
    }
}

struct ControllerBindingEditor: View {
    let input: ControllerInput
    @Environment(ControllerMappingSettings.self) private var mappings
    @State private var editorState = ControllerBindingEditorState(action: nil)

    var body: some View {
        Form {
            Section("Controller input") { Text(input.label) }
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
            Section {
                Button("Clear Mapping", role: .destructive) {
                    editorState = ControllerBindingEditorState(action: nil)
                }
            }
        }
        .navigationTitle(input.label)
        .onAppear {
            editorState = ControllerBindingEditorState(
                action: mappings.draftProfile.action(for: input)
            )
        }
        .onChange(of: editorState) { _, newValue in
            mappings.setAction(newValue.action, for: input)
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
