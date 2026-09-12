import SwiftUI

/// Native management for the global, persisted terminal Control Keys list.
struct ControlKeysManagementView: View {
    @Environment(AppSettings.self) private var settings
    @State private var isAddingControl = false

    var body: some View {
        List {
            Section("Control Keys") {
                ForEach(settings.terminalControlKeys) { control in
                    NavigationLink {
                        ControlKeyEditorView(control: control)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(control.name)
                            Text(control.chord.suggestedName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    var controls = settings.terminalControlKeys
                    controls.remove(atOffsets: offsets)
                    settings.replaceTerminalControlKeys(controls)
                }
                .onMove { source, destination in
                    var controls = settings.terminalControlKeys
                    controls.move(fromOffsets: source, toOffset: destination)
                    settings.replaceTerminalControlKeys(controls)
                }
            }

            Section {
                Button("Restore Defaults", systemImage: "arrow.counterclockwise", role: .destructive) {
                    settings.restoreDefaultTerminalControlKeys()
                }
            } footer: {
                Text("Restoring defaults replaces the current Control Keys collection.")
            }
        }
        .navigationTitle("Control Keys")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") {
                    isAddingControl = true
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
        }
        .navigationDestination(isPresented: $isAddingControl) {
            ControlKeyEditorView(control: nil)
        }
    }
}

private struct ControlKeyEditorView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let existingControl: TerminalControlKey?
    @State private var name: String
    @State private var baseKey: TerminalControlBaseKey
    @State private var letter: String
    @State private var isControl = false
    @State private var isAlt = false
    @State private var isShift = false

    private static let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)

    init(control: TerminalControlKey?) {
        existingControl = control
        let chord = control?.chord ?? TerminalControlChord(
            baseKey: .letter,
            letter: "c",
            modifiers: [.control]
        )
        _name = State(initialValue: control?.name ?? chord.suggestedName)
        _baseKey = State(initialValue: chord.baseKey)
        _letter = State(initialValue: chord.letter ?? "a")
        _isControl = State(initialValue: chord.modifiers.contains(.control))
        _isAlt = State(initialValue: chord.modifiers.contains(.alt))
        _isShift = State(initialValue: chord.modifiers.contains(.shift))
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
            }

            Section("Terminal chord") {
                Picker("Key", selection: $baseKey) {
                    ForEach(TerminalControlBaseKey.allCases, id: \.self) { key in
                        Text(key.label).tag(key)
                    }
                }

                if baseKey == .letter {
                    Picker("Letter", selection: $letter) {
                        ForEach(Self.letters, id: \.self) { letter in
                            Text(letter.uppercased()).tag(letter)
                        }
                    }
                    Toggle("Control", isOn: $isControl)
                    Toggle("Alt", isOn: $isAlt)
                    Toggle("Shift", isOn: $isShift)
                } else if baseKey == .tab {
                    Toggle("Shift", isOn: $isShift)
                } else {
                    Text("This terminal key has no reliably representable modifiers.")
                        .foregroundStyle(.secondary)
                }

                Text(chord.suggestedName)
                    .foregroundStyle(.secondary)
            }

            if let validationError {
                Section("Not available") {
                    Text(validationError.explanation)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(existingControl == nil ? "Add Control Key" : "Edit Control Key")
        .onChange(of: baseKey) { _, key in
            if key != .letter {
                isControl = false
                isAlt = false
            }
            if key != .tab {
                isShift = false
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
                .disabled(validationError != nil)
            }
        }
    }

    private var chord: TerminalControlChord {
        var modifiers: Set<TerminalControlModifier> = []
        if isControl { modifiers.insert(.control) }
        if isAlt { modifiers.insert(.alt) }
        if isShift { modifiers.insert(.shift) }
        return TerminalControlChord(
            baseKey: baseKey,
            letter: baseKey == .letter ? letter : nil,
            modifiers: modifiers
        )
    }

    private var candidate: TerminalControlKey {
        TerminalControlKey(
            id: existingControl?.id ?? "terminal.draft",
            name: name,
            chord: chord
        )
    }

    private var validationError: TerminalControlKeyValidationError? {
        candidate.validationError(among: settings.terminalControlKeys)
    }

    private func save() {
        guard validationError == nil else { return }
        let control = TerminalControlKey(
            id: existingControl?.id ?? "terminal.custom.\(UUID().uuidString.lowercased())",
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            chord: chord
        )
        var controls = settings.terminalControlKeys
        if let index = controls.firstIndex(where: { $0.id == control.id }) {
            controls[index] = control
        } else {
            controls.append(control)
        }
        settings.replaceTerminalControlKeys(controls)
        dismiss()
    }
}
