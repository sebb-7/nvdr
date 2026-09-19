import SwiftUI
import UIKit

/// A standard list-based editor so every mapping remains reachable with VoiceOver.
struct ControllerMappingView: View {
    @Environment(ControllerMappingSettings.self) private var mappings
    @Environment(DualSenseControllerAdapter.self) private var controllerAdapter

    @State private var saveConfirmation: String?

    var body: some View {
        List(ControllerInput.allCases) { input in
            // Keep the destination on the row itself. The former value-based
            // link relied on a destination attached to the enclosing list,
            // which could defer VoiceOver activation until that list was
            // being popped.
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
        .navigationTitle("Controller Mapping")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if mappings.hasUnsavedChanges {
                    Text("Unsaved mapping changes")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Discard Unsaved Changes", role: .destructive) {
                        mappings.discardDraft()
                    }
                }
                Button("Save Mappings") {
                    mappings.saveDraft()
                    saveConfirmation = "Controller mappings saved."
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: "Controller mappings saved."
                    )
                }
                .disabled(!mappings.hasUnsavedChanges)
                .accessibilityHint("Saves every edited controller binding.")
                if controllerAdapter.controllerHasRemappedElements {
                    Text("This controller follows its current iOS button remapping.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let saveConfirmation {
                    Text(saveConfirmation)
                        .font(.footnote)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .padding()
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

struct ControllerBindingEditor: View {
    let input: ControllerInput
    @Environment(ControllerMappingSettings.self) private var mappings
    @State private var key: WindowsKeyboardKey = .up
    @State private var modifiers: Set<ControllerKeyboardModifier> = []

    var body: some View {
        Form {
            Section("Controller input") { Text(input.label) }
            Section("Keyboard") {
                Picker("Primary key", selection: $key) {
                    ForEach(WindowsKeyboardKey.allCases) { key in Text(key.label).tag(key) }
                }
                ForEach(ControllerKeyboardModifier.allCases) { modifier in
                    Toggle(modifier.label, isOn: modifierBinding(modifier))
                }
            }
            Section {
                Button("Clear Mapping", role: .destructive) { mappings.setAction(nil, for: input) }
            }
        }
        .navigationTitle(input.label)
        .onAppear { loadCurrentBinding() }
        .onChange(of: key) { _, _ in saveDraftBinding() }
        .onChange(of: modifiers) { _, _ in saveDraftBinding() }
    }

    private func modifierBinding(_ modifier: ControllerKeyboardModifier) -> Binding<Bool> {
        Binding(get: { modifiers.contains(modifier) }, set: { selected in
            if selected { modifiers.insert(modifier) } else { modifiers.remove(modifier) }
        })
    }

    private func loadCurrentBinding() {
        guard case .keyboard(let action) = mappings.draftProfile.action(for: input) else { return }
        key = action.key
        modifiers = action.modifiers
    }

    private func saveDraftBinding() {
        mappings.setAction(.keyboard(.init(key: key, modifiers: modifiers)), for: input)
    }
}
