import SwiftUI
import os

/// A VoiceOver-first accessible conversation surface for a terminal model.
struct TerminalPresentationView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(InteractionFeedback.self) private var interactionFeedback
    let presentation: TerminalPresentationModel
    let openSnapshot: (AccessibleConversationSnapshot) -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @State private var nativeInputBuffer = TerminalNativeInputBuffer()
    @State private var isManagingControlKeys = false

    var body: some View {
        @Bindable var presentation = presentation
        VStack(spacing: 0) {
            TerminalConversationList(
                presentation: presentation,
                openSnapshot: openSnapshot
            )
            TerminalPresentationStatusView(presentation: presentation)
            TerminalInputControls(
                presentation: presentation,
                inputBuffer: nativeInputBuffer,
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
        .onChange(of: presentation.lastInteractionFeedback?.id) { _, _ in
            if let request = presentation.lastInteractionFeedback {
                interactionFeedback.play(request.kind)
            }
        }
        .onDisappear {
            presentation.endEditingSession()
        }
    }

}

private struct TerminalConversationList: View {
    let presentation: TerminalPresentationModel
    let openSnapshot: (AccessibleConversationSnapshot) -> Void

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
                        openSnapshot: openSnapshot
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

    var body: some View {
        NativeTerminalConversationRow(
            entry: entry,
            accessibilityText: presentation.accessibilityLabel(for: entry),
            actions: presentation.accessibilityActions(for: entry),
            onAction: perform,
            onAccessibilityFocusChanged: { isFocused in
                if isFocused {
                    presentation.setLiveOutputFocusedConversationEntryID(entry.id)
                    presentation.setLiveOutputInputFocused(false)
                } else {
                    presentation.setLiveOutputFocusedConversationEntryID(nil)
                }
            }
        )
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
                    .accessibilityLabel("Shell prompt, \(shellPromptContext)")
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
    let inputBuffer: TerminalNativeInputBuffer
    let controlKeys: [TerminalControlKey]
    let manageControlKeys: () -> Void
    var body: some View {
        VStack(alignment: .leading) {
            StableTerminalInputField(
                inputBuffer: inputBuffer,
                initialText: presentation.inputText,
                onSubmit: sendFromInput,
                onClear: {
                    inputBuffer.clear()
                    presentation.clearInput()
                },
                onAccessibilityFocusChanged: { isFocused in
                    presentation.setLiveOutputFocusedConversationEntryID(nil)
                    presentation.setLiveOutputInputFocused(isFocused)
                }
            )

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
        let text = inputBuffer.currentText
        // Synchronize once at submission for retry/error presentation. Native
        // editing never binds each Braille character through SwiftUI.
        presentation.inputText = text
        Task {
            await presentation.submitInput(text)
            if presentation.lastInputError == nil {
                inputBuffer.clear()
            }
        }
    }
}

/// A single persistent UIKit editor is more reliable for Braille Screen
/// Input than a SwiftUI TextField whose identity and focus can be recreated
/// while terminal output is arriving. It owns its text, selection, marked
/// input, first responder state, and accessibility identity during editing.
private struct StableTerminalInputField: UIViewRepresentable {
    let inputBuffer: TerminalNativeInputBuffer
    let initialText: String
    let onSubmit: () -> Void
    let onClear: () -> Void
    let onAccessibilityFocusChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> NativeTerminalTextField {
        let field = NativeTerminalTextField(frame: .zero)
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
        field.accessibilityIdentifier = "terminal-input"
        return field
    }

    func updateUIView(_ field: NativeTerminalTextField, context: Context) {
        context.coordinator.parent = self
        field.recordLifecycle("updateUIView-before-model-propagation")
        inputBuffer.attach(
            editorID: field.editorID,
            initialText: initialText,
            writeNativeText: { [weak field] text in
                guard let field, field.text != text else { return }
                field.text = text
            }
        )
        field.onAccessibilityFocusChanged = { isFocused in
            inputBuffer.nativeAccessibilityFocusDidChange(isFocused)
            onAccessibilityFocusChanged(isFocused)
        }
        field.onSubmit = onSubmit
        field.onClear = onClear
        field.configureAccessibilityActions()
        field.recordLifecycle("updateUIView-after-model-propagation")
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: StableTerminalInputField

        init(_ parent: StableTerminalInputField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            guard let field = field as? NativeTerminalTextField else { return }
            let text = field.text ?? ""
            let eventPrefix = text.count == 1 ? "firstCharacter" : "subsequentCharacter"
            field.recordLifecycle("\(eventPrefix)-before-native-buffer-sync")
            parent.inputBuffer.nativeTextDidChange(text)
            field.recordLifecycle("\(eventPrefix)-after-native-buffer-sync")
            if text.count == 1 {
                field.recordLifecycle("firstCharacter-before-next-character")
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.inputBuffer.nativeEditingDidBegin()
            (textField as? NativeTerminalTextField)?.recordLifecycle("textFieldDidBeginEditing")
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.inputBuffer.nativeEditingDidEnd()
            (textField as? NativeTerminalTextField)?.recordLifecycle("textFieldDidEndEditing")
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }
}

private final class NativeTerminalTextField: UITextField {
    let editorID = UUID()
    var onAccessibilityFocusChanged: ((Bool) -> Void)?
    var onSubmit: (() -> Void)?
    var onClear: (() -> Void)?

    #if DEBUG
    private static let lifecycleLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.sebb7.farrelay",
        category: "TerminalNativeEditor"
    )
    #endif

    override func accessibilityActivate() -> Bool {
        recordLifecycle("accessibilityActivate-before")
        let activated = becomeFirstResponder()
        recordLifecycle("accessibilityActivate-after")
        return activated
    }

    func configureAccessibilityActions() {
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Send Command") { [weak self] _ in
                self?.recordLifecycle("accessibilitySend-before-submission")
                self?.onSubmit?()
                return true
            },
            UIAccessibilityCustomAction(name: "Clear Input") { [weak self] _ in
                self?.recordLifecycle("accessibilityClear-before-buffer-clear")
                self?.onClear?()
                return true
            }
        ]
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        onAccessibilityFocusChanged?(true)
        recordLifecycle("accessibilityFocusGained")
    }

    override func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        onAccessibilityFocusChanged?(false)
        recordLifecycle("accessibilityFocusLost")
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        recordLifecycle("becomeFirstResponder")
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        recordLifecycle("resignFirstResponder")
        return resignedFirstResponder
    }

    func recordLifecycle(_ event: String) {
        #if DEBUG
        let textLength = (text ?? "").count
        Self.lifecycleLogger.debug(
            "event=\(event, privacy: .public) firstResponder=\(self.isFirstResponder, privacy: .public) windowAttached=\(self.window != nil, privacy: .public) textLength=\(textLength, privacy: .public)"
        )
        #endif
    }
}

