import SwiftUI

/// A standard list-based editor so every mapping remains reachable with VoiceOver.
struct ControllerMappingView: View {
    @Environment(ControllerMappingSettings.self) private var mappings

    var body: some View {
        List(ControllerInput.allCases) { input in
            NavigationLink(value: input) {
                VStack(alignment: .leading) {
                    Text(input.label)
                    Text(summary(for: mappings.activeProfile.action(for: input)))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Controller Mapping")
        .navigationDestination(for: ControllerInput.self) { input in
            ControllerBindingEditor(input: input)
        }
    }

    private func summary(for action: ControllerAction?) -> String {
        guard case .keyboard(let keyboard) = action else { return "Unassigned" }
        let modifiers = keyboard.modifiers.map(\.label).sorted()
        return (modifiers + [keyboard.key.label]).joined(separator: "+")
    }
}

private struct ControllerBindingEditor: View {
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
                Button("Save Mapping") { mappings.setAction(.keyboard(.init(key: key, modifiers: modifiers)), for: input) }
                Button("Clear Mapping", role: .destructive) { mappings.setAction(nil, for: input) }
            }
        }
        .navigationTitle(input.label)
        .onAppear { loadCurrentBinding() }
    }

    private func modifierBinding(_ modifier: ControllerKeyboardModifier) -> Binding<Bool> {
        Binding(get: { modifiers.contains(modifier) }, set: { selected in
            if selected { modifiers.insert(modifier) } else { modifiers.remove(modifier) }
        })
    }

    private func loadCurrentBinding() {
        guard case .keyboard(let action) = mappings.activeProfile.action(for: input) else { return }
        key = action.key
        modifiers = action.modifiers
    }
}
