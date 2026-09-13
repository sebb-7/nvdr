import SwiftUI

/// A VoiceOver-first accessible conversation surface for a terminal model.
struct TerminalPresentationView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(InteractionFeedback.self) private var interactionFeedback
    let presentation: TerminalPresentationModel
    let openSnapshot: (AccessibleConversationSnapshot) -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @AccessibilityFocusState(for: .voiceOver) private var voiceOverFocus: TerminalAccessibilityFocus?
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
                voiceOverFocus: $voiceOverFocus,
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
        }
        .onChange(of: isVoiceOverEnabled) { _, isEnabled in
            presentation.setLiveOutputVoiceOverEnabled(isEnabled)
        }
        .onChange(of: voiceOverFocus) { _, focus in
            switch focus {
            case .conversation(let entryID):
                presentation.setLiveOutputFocusedConversationEntryID(entryID)
                presentation.setLiveOutputInputFocused(false)
            case .input:
                presentation.setLiveOutputFocusedConversationEntryID(nil)
                presentation.setLiveOutputInputFocused(true)
            case nil:
                presentation.setLiveOutputFocusedConversationEntryID(nil)
                presentation.setLiveOutputInputFocused(false)
            }
        }
        .onChange(of: presentation.liveOutputAnnouncement?.id) { _, _ in
            guard isVoiceOverEnabled, let announcement = presentation.liveOutputAnnouncement else { return }
            LiveOutputAnnouncementDelivery.deliver(announcement)
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
                .conversationAccessibilityActions(presentation.accessibilityActions(for: entry)) { action in
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
                    .conversationAccessibilityActions(presentation.accessibilityActions(for: entry)) { action in
                        perform(action)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                if entry.role == .incomingContent {
                    Button("Open Snapshot", systemImage: "doc.text") {
                        openSnapshotIfAvailable()
                    }
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
    let voiceOverFocus: AccessibilityFocusState<TerminalAccessibilityFocus?>.Binding
    let controlKeys: [TerminalControlKey]
    let manageControlKeys: () -> Void
    @FocusState private var isInputEditing: Bool

    var body: some View {
        VStack(alignment: .leading) {
            TextField("Terminal input", text: $inputText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($isInputEditing)
                .onSubmit {
                    sendFromInput()
                }
                .conversationAccessibilityActions(presentation.inputAccessibilityActions()) { action in
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
                .accessibilityFocused(voiceOverFocus, equals: .input)

            HStack {
                Button("Send", systemImage: "arrow.up.circle") {
                    sendFromInput()
                }
                .buttonStyle(.borderedProminent)
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
        let retainEditingFocus = isInputEditing
        Task {
            await presentation.submitInputText()
            if retainEditingFocus, presentation.lastInputError == nil {
                isInputEditing = true
            }
        }
    }
}

private extension View {
    func conversationAccessibilityActions(
        _ actions: [ConversationAccessibilityAction],
        perform: @escaping (ConversationAccessibilityAction) -> Void
    ) -> some View {
        modifier(ConversationAccessibilityActionsModifier(actions: actions, perform: perform))
    }
}

private struct ConversationAccessibilityActionsModifier: ViewModifier {
    let actions: [ConversationAccessibilityAction]
    let perform: (ConversationAccessibilityAction) -> Void

    func body(content: Content) -> some View {
        switch actions.count {
        case 0:
            content
        case 1:
            content.accessibilityAction(named: actions[0].name) { perform(actions[0]) }
        case 2:
            content
                .accessibilityAction(named: actions[0].name) { perform(actions[0]) }
                .accessibilityAction(named: actions[1].name) { perform(actions[1]) }
        default:
            content
                .accessibilityAction(named: actions[0].name) { perform(actions[0]) }
                .accessibilityAction(named: actions[1].name) { perform(actions[1]) }
                .accessibilityAction(named: actions[2].name) { perform(actions[2]) }
        }
    }
}
