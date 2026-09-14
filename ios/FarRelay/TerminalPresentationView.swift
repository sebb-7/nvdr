import SwiftUI

/// A VoiceOver-first accessible conversation surface for a terminal model.
struct TerminalPresentationView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(InteractionFeedback.self) private var interactionFeedback
    let presentation: TerminalPresentationModel
    let openSnapshot: (AccessibleConversationSnapshot) -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @AccessibilityFocusState(for: .voiceOver) private var voiceOverFocus: TerminalAccessibilityFocus?
    @State private var isInputEditing = false
    @State private var isManagingControlKeys = false

    var body: some View {
        @Bindable var presentation = presentation
        VStack(spacing: 0) {
            TerminalConversationList(
                presentation: presentation,
                openSnapshot: openSnapshot,
                voiceOverFocus: $voiceOverFocus
            )
            TerminalPresentationStatusView(presentation: presentation)
            TerminalInputControls(
                presentation: presentation,
                inputText: $presentation.inputText,
                isInputEditing: $isInputEditing,
                controlKeys: settings.terminalControlKeys,
                manageControlKeys: { isManagingControlKeys = true }
            )
        }
        .navigationTitle("SSH Terminal")
        .navigationDestination(isPresented: $isManagingControlKeys) {
            ControlKeysManagementView()
        }
        .onAppear {
            presentation.setLiveOutputVoiceOverEnabled(isVoiceOverEnabled)
            presentation.setDynamicReadingEnabled(settings.dynamicReadingEnabled)
            presentation.setVoiceOverActionPreferences(settings.voiceOverActionPreferences)
        }
        .onChange(of: isVoiceOverEnabled) { _, isEnabled in
            presentation.setLiveOutputVoiceOverEnabled(isEnabled)
        }
        .onChange(of: settings.dynamicReadingEnabled) { _, isEnabled in
            presentation.setDynamicReadingEnabled(isEnabled)
        }
        .onChange(of: settings.voiceOverActionPreferences) { _, preferences in
            presentation.setVoiceOverActionPreferences(preferences)
        }
        .onChange(of: voiceOverFocus) { _, focus in
            switch focus {
            case .conversation(let entryID):
                presentation.setLiveOutputFocusedConversationEntryID(entryID)
                presentation.setLiveOutputInputFocused(false)
            case .input:
                presentation.setLiveOutputFocusedConversationEntryID(nil)
                presentation.setLiveOutputInputFocused(true)
                isInputEditing = true
            case nil:
                presentation.setLiveOutputFocusedConversationEntryID(nil)
                presentation.setLiveOutputInputFocused(false)
            }
        }
        .onChange(of: presentation.lastInteractionFeedback?.id) { _, _ in
            if let request = presentation.lastInteractionFeedback {
                interactionFeedback.play(request.kind)
            }
        }
    }

}

private enum TerminalAccessibilityFocus: Hashable {
    case conversation(UUID)
    case input
}

private struct TerminalConversationList: View {
    let presentation: TerminalPresentationModel
    let openSnapshot: (AccessibleConversationSnapshot) -> Void
    let voiceOverFocus: AccessibilityFocusState<TerminalAccessibilityFocus?>.Binding

    var body: some View {
        List {
            if presentation.accessibleSnapshot?.isAlternateScreen == true {
                ForEach(presentation.alternateScreenLines, id: \.logicalIndex) { line in
                    Text(line.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(presentation.conversationEntries) { entry in
                    TerminalConversationEntryView(
                        entry: entry,
                        presentation: presentation,
                        openSnapshot: openSnapshot,
                        voiceOverFocus: voiceOverFocus
                    )
                }
            }
        }
        .accessibilityIdentifier("terminal-conversation")
    }
}

private struct TerminalConversationEntryView: View {
    let entry: AccessibleConversationEntry
    let presentation: TerminalPresentationModel
    let openSnapshot: (AccessibleConversationSnapshot) -> Void
    let voiceOverFocus: AccessibilityFocusState<TerminalAccessibilityFocus?>.Binding

    var body: some View {
        if entry.isCommand {
            Text(entry.presentationText)
                .textSelection(.enabled)
                .accessibilityLabel(presentation.accessibilityLabel(for: entry))
                .accessibilityHeading(.h3)
                .accessibilityFocused(voiceOverFocus, equals: .conversation(entry.id))
                .namedAccessibilityActions(
                    presentation.accessibilityActions(for: entry),
                    name: \.name
                ) { action in
                    perform(action)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("terminal-command-\(entry.id)")
        } else {
            VStack(alignment: .leading) {
                Text(entry.presentationText)
                    .textSelection(.enabled)
                    .accessibilityLabel(presentation.accessibilityLabel(for: entry))
                    .accessibilityFocused(voiceOverFocus, equals: .conversation(entry.id))
                    .namedAccessibilityActions(
                        presentation.accessibilityActions(for: entry),
                        name: \.name
                    ) { action in
                        perform(action)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                if entry.role == .incomingContent {
                    Button("Open Snapshot", systemImage: "doc.text") {
                        openSnapshotIfAvailable()
                    }
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("terminal-open-snapshot-\(entry.id)")
                }
            }
            .accessibilityIdentifier("terminal-content-\(entry.id)")
        }
    }

    private func perform(_ action: ConversationAccessibilityAction) {
        switch action {
        case .copy:
            copyEntry()
        case .runAgain:
            Task {
                await presentation.runAgain(commandID: entry.id)
            }
        case .openSnapshot:
            openSnapshotIfAvailable()
        case .sendCommand, .clearInput, .copyAll:
            break
        }
    }

    private func copyEntry() {
        guard presentation.performCopy(for: entry.id) else { return }
        AccessibilityNotification.Announcement("Copied").post()
    }

    private func openSnapshotIfAvailable() {
        guard let snapshot = presentation.performOpenSnapshot(for: entry.id) else { return }
        openSnapshot(snapshot)
    }
}

private struct TerminalPresentationStatusView: View {
    let presentation: TerminalPresentationModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(presentation.sessionState.accessibilityLabel)
                .accessibilityIdentifier("terminal-session-state")
            if let shellPromptContext = presentation.shellPromptContext {
                Text(shellPromptContext)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Shell prompt context: \(shellPromptContext)")
            }
            if presentation.accessibleSnapshot?.isAlternateScreen == true {
                Text("Alternate screen active")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Terminal alternate screen active")
            }
            if let lastInputError = presentation.lastInputError {
                Text(lastInputError)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Terminal input error: \(lastInputError)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .accessibilityElement(children: .contain)
    }
}

private struct TerminalInputControls: View {
    let presentation: TerminalPresentationModel
    @Binding var inputText: String
    @Binding var isInputEditing: Bool
    let controlKeys: [TerminalControlKey]
    let manageControlKeys: () -> Void
    var body: some View {
        VStack(alignment: .leading) {
            StableTerminalInputField(
                text: $inputText,
                isEditing: $isInputEditing,
                onSubmit: sendFromInput
            )
            .namedAccessibilityActions(
                presentation.inputAccessibilityActions(),
                name: \.name
            ) { action in
                switch action {
                case .sendCommand:
                    sendFromInput()
                case .clearInput:
                    presentation.clearInput()
                default:
                    break
                }
            }
            .accessibilityLabel("Terminal input")
            .accessibilityIdentifier("terminal-input")

            HStack {
                Button("Send", systemImage: "arrow.up.circle") {
                    sendFromInput()
                }
                .buttonStyle(.borderedProminent)
                .disabled(presentation.isSubmittingInput)
                .accessibilityIdentifier("terminal-send")

                Menu("Control Keys", systemImage: "keyboard") {
                    ForEach(controlKeys) { control in
                        Button(control.name) {
                            Task {
                                await presentation.send(controlID: control.id, from: controlKeys)
                            }
                        }
                    }
                    Divider()
                    Button("Manage Control Keys", systemImage: "slider.horizontal.3") {
                        manageControlKeys()
                    }
                }
                .accessibilityIdentifier("terminal-control-keys")
            }
        }
        .padding()
    }

    private func sendFromInput() {
        isInputEditing = true
        Task {
            await presentation.submitInputText()
            // Restore only native text editing focus. Moving VoiceOver focus to
            // the field after every Send breaks Braille Screen Input and causes
            // VoiceOver to leave the text editor between repeated commands.
            isInputEditing = true
        }
    }
}

/// A single persistent UIKit editor is more reliable for Braille Screen
/// Input than a SwiftUI TextField whose identity and focus can be recreated
/// while terminal output is arriving. Binding updates are one-way guarded so
/// caret/selection state remains owned by UITextField during editing.
private struct StableTerminalInputField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.borderStyle = .roundedRect
        field.returnKeyType = .send
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.enablesReturnKeyAutomatically = false
        field.accessibilityLabel = "Terminal input"
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text {
            field.text = text
        }
        if isEditing, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isEditing, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: StableTerminalInputField

        init(_ parent: StableTerminalInputField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.isEditing = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            // Do not clear this during Send; SwiftUI may update the wrapper
            // while the async terminal write is in flight.
            if !textField.isFirstResponder {
                parent.isEditing = false
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

