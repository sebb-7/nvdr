import SwiftUI

/// A VoiceOver-first accessible conversation surface for a terminal model.
struct TerminalPresentationView: View {
    let presentation: TerminalPresentationModel
    let openSnapshot: (AccessibleConversationSnapshot) -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @AccessibilityFocusState(for: .voiceOver) private var voiceOverFocus: TerminalAccessibilityFocus?

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
                voiceOverFocus: $voiceOverFocus
            )
        }
        .navigationTitle("SSH Terminal")
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
            Text(entry.text)
                .textSelection(.enabled)
                .accessibilityLabel(presentation.accessibilityLabel(for: entry))
                .accessibilityHeading(.h3)
                .accessibilityFocused(voiceOverFocus, equals: .conversation(entry.id))
                .accessibilityAction(named: "Run Again") {
                    Task {
                        await presentation.runAgain(commandID: entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("terminal-command-\(entry.id)")
        } else {
            VStack(alignment: .leading) {
                Text(entry.text)
                    .textSelection(.enabled)
                    .accessibilityLabel(presentation.accessibilityLabel(for: entry))
                    .accessibilityFocused(voiceOverFocus, equals: .conversation(entry.id))
                    .frame(maxWidth: .infinity, alignment: .leading)

                if entry.role == .incomingContent {
                    Button("Open Snapshot", systemImage: "doc.text") {
                        guard let snapshot = presentation.captureSnapshot(for: entry.id) else { return }
                        openSnapshot(snapshot)
                    }
                    .accessibilityIdentifier("terminal-open-snapshot-\(entry.id)")
                }
            }
            .accessibilityIdentifier("terminal-content-\(entry.id)")
        }
    }
}

private struct TerminalPresentationStatusView: View {
    let presentation: TerminalPresentationModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(presentation.sessionState.accessibilityLabel)
                .accessibilityIdentifier("terminal-session-state")
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

    var body: some View {
        VStack(alignment: .leading) {
            TextField("Terminal input", text: $inputText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit {
                    Task {
                        await presentation.submitInputText()
                    }
                }
                .accessibilityIdentifier("terminal-input")
                .accessibilityFocused(voiceOverFocus, equals: .input)

            HStack {
                Button("Send", systemImage: "arrow.up.circle") {
                    Task {
                        await presentation.submitInputText()
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("terminal-send")

                Menu("Terminal keys", systemImage: "keyboard") {
                    ForEach(TerminalPresentationAction.allCases) { action in
                        Button(action.title) {
                            Task {
                                await presentation.send(action)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("terminal-keys")
            }
        }
        .padding()
    }
}
