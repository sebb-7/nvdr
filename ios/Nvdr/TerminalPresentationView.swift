import SwiftUI

/// A VoiceOver-first terminal surface for a supplied presentation model.
struct TerminalPresentationView: View {
    let presentation: TerminalPresentationModel

    var body: some View {
        @Bindable var presentation = presentation
        VStack(spacing: 0) {
            TerminalPresentationStatusView(presentation: presentation)
            TerminalReviewControls(presentation: presentation)
            TerminalLineList(presentation: presentation)
            TerminalInputControls(presentation: presentation, inputText: $presentation.inputText)
        }
        .task {
            while !Task.isCancelled {
                presentation.refresh()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .navigationTitle("SSH Terminal")
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

private struct TerminalReviewControls: View {
    let presentation: TerminalPresentationModel

    var body: some View {
        HStack {
            if presentation.isReviewing {
                Button("Previous line", systemImage: "chevron.up") {
                    presentation.moveReview(by: -1)
                }
                Button("Next line", systemImage: "chevron.down") {
                    presentation.moveReview(by: 1)
                }
                Button("Return to live terminal", systemImage: "dot.radiowaves.left.and.right") {
                    presentation.returnToLive()
                }
                .accessibilityIdentifier("terminal-return-live")
            } else {
                Button("Review terminal content", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    presentation.enterReview()
                }
                .accessibilityIdentifier("terminal-enter-review")
            }
            Spacer()
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.bottom)
    }
}

private struct TerminalLineList: View {
    let presentation: TerminalPresentationModel

    var body: some View {
        List {
            Section("Terminal content") {
                ForEach(presentation.lines, id: \.logicalIndex) { line in
                    Button {
                        presentation.enterReview(at: line.logicalIndex)
                    } label: {
                        Text(line.text.isEmpty ? "Blank line" : line.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(presentation.accessibilityLabel(for: line))
                    .accessibilityHint("Double-tap to keep reviewing this terminal line.")
                    .accessibilityIdentifier("terminal-line-\(line.logicalIndex)")
                }
            }
        }
        .accessibilityIdentifier("terminal-content")
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
