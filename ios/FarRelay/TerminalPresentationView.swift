import SwiftUI

/// A VoiceOver-first accessible conversation surface for a terminal model.
struct TerminalPresentationView: View {
    let presentation: TerminalPresentationModel

    var body: some View {
        @Bindable var presentation = presentation
        VStack(spacing: 0) {
            TerminalConversationList(presentation: presentation)
            TerminalPresentationStatusView(presentation: presentation)
            TerminalInputControls(presentation: presentation, inputText: $presentation.inputText)
        }
        .navigationTitle("SSH Terminal")
    }
}

private struct TerminalConversationList: View {
    let presentation: TerminalPresentationModel

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
                    TerminalConversationEntryView(entry: entry, presentation: presentation)
                }
            }
        }
        .accessibilityIdentifier("terminal-conversation")
    }
}

private struct TerminalConversationEntryView: View {
    let entry: AccessibleConversationEntry
    let presentation: TerminalPresentationModel

    var body: some View {
        if entry.isCommand {
            Text(entry.text)
                .textSelection(.enabled)
                .accessibilityLabel(presentation.accessibilityLabel(for: entry))
                .accessibilityHeading(.h3)
                .accessibilityAction(named: "Run Again") {
                    Task {
                        await presentation.runAgain(commandID: entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("terminal-command-\(entry.id)")
        } else {
            Text(entry.text)
                .textSelection(.enabled)
                .accessibilityLabel(presentation.accessibilityLabel(for: entry))
                .frame(maxWidth: .infinity, alignment: .leading)
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
