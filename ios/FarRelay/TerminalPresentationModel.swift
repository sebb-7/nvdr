import Foundation
import Observation

/// User-facing lifecycle information for an interactive terminal.
enum TerminalPresentationSessionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case ended
    case failed(String)
    case closed

    var accessibilityLabel: String {
        switch self {
        case .idle:
            "Terminal ready to connect."
        case .connecting:
            "Terminal connecting."
        case .connected:
            "Terminal connected."
        case .ended:
            "Terminal session ended."
        case .failed(let message):
            "Terminal failed: \(message)"
        case .closed:
            "Terminal session closed."
        }
    }
}

/// The presentation-facing terminal capability. This deliberately excludes
/// SSH transport, terminal-parser, and UI implementation details.
@MainActor
protocol TerminalPresentationSession: AnyObject {
    var terminalPresentationSnapshot: TerminalSnapshot { get }
    var terminalPresentationState: TerminalPresentationSessionState { get }
    func observeTerminalPresentationUpdates(
        _ observer: @escaping @MainActor (TerminalSnapshot, TerminalPresentationSessionState) -> Void
    )
    func sendTerminalInput(_ bytes: Data) async throws
    func resizeTerminal(columns: Int, rows: Int) async throws
}

private struct CompletedLineIngest {
    var finalizedEntries: [AccessibleConversationEntry] = []
    var openGroup: AccessibleConversationEntry?
}

/// UI-facing accessible conversation state derived from terminal semantics.
@Observable
@MainActor
final class TerminalPresentationModel {
    private(set) var sessionState: TerminalPresentationSessionState
    private(set) var accessibleSnapshot: AccessibleTerminalSnapshot?
    private(set) var conversationEntries: [AccessibleConversationEntry] = []
    private(set) var alternateScreenLines: [AccessibleTerminalLine] = []
    private(set) var lastInputError: String?
    private(set) var liveOutputAnnouncement: LiveOutputAnnouncement?
    private(set) var pendingDynamicReadingAnnouncements: [DynamicReadingAnnouncement] = []
    private(set) var lastInteractionFeedback: InteractionFeedbackRequest?
    var onIncomingConversationContent: (@MainActor () -> Void)?
    private(set) var shellPromptContext: String?
    var inputText = ""
    private(set) var isSubmittingInput = false
    var copyToClipboard: @MainActor (String) -> Void = { AppClipboard.copy($0) }

    private var accessibilityModel = TerminalAccessibilityModel()
    private var session: (any TerminalPresentationSession)?
    private var streamingEntryID: UUID?
    private var openOutputEntryID: UUID?
    private var openGroupPartialLine: String?
    private var lastOutboundCommandText: String?
    private var announcedLargeOutputIDs: Set<UUID> = []
    private var observationGeneration = 0
    private let liveOutputPolicy = LiveOutputAnnouncementPolicy()
    private var liveOutputAnnouncementTask: Task<Void, Never>?
    private var liveOutputContext = LiveOutputAnnouncementContext()
    private var focusedConversationEntryID: UUID?
    private var sessionID = UUID()
    private var dynamicReadingContext = DynamicReadingContext()
    private let dynamicReadingQueue = DynamicReadingQueue()
    private var voiceOverActionPreferences = VoiceOverActionPreferences.defaults

    init(session: (any TerminalPresentationSession)? = nil) {
        self.session = session
        sessionState = session?.terminalPresentationState ?? .idle
    }

    /// Starts a new terminal lifetime. A coordinator calls this before it has
    /// a live session to attach, so old history cannot bleed into a new shell.
    func beginConnecting() {
        session = nil
        updateSessionState(.connecting)
        resetPresentation()
    }

    /// Updates feature-level lifecycle state before a terminal session exists
    /// or after its transport has been released.
    func setSessionState(_ state: TerminalPresentationSessionState) {
        updateSessionState(state)
    }

    /// Attaches a terminal session owned by a higher-level feature coordinator.
    /// Snapshot updates arrive through the terminal's existing semantic boundary,
    /// rather than by polling terminal text from the SwiftUI view.
    func attach(_ session: any TerminalPresentationSession) {
        self.session = session
        resetPresentation()
        let generation = observationGeneration
        session.observeTerminalPresentationUpdates { [weak self] snapshot, state in
            guard let self, self.observationGeneration == generation else { return }
            _ = self.process(snapshot, sessionState: state)
        }
        refresh()
    }

    func refresh() {
        guard let session else { return }
        _ = process(
            session.terminalPresentationSnapshot,
            sessionState: session.terminalPresentationState
        )
    }

    /// Consumes semantic terminal updates without reparsing terminal bytes.
    @discardableResult
    func process(
        _ terminalSnapshot: TerminalSnapshot,
        sessionState: TerminalPresentationSessionState
    ) -> TerminalAccessibilityUpdate {
        updateSessionState(sessionState)
        let establishesBaseline = accessibilityModel.accessibleSnapshot == nil
        let update = accessibilityModel.process(terminalSnapshot)
        accessibleSnapshot = update.snapshot

        if update.snapshot.isAlternateScreen {
            alternateScreenLines = usefulLines(in: update.snapshot)
            streamingEntryID = nil
            openOutputEntryID = nil
            openGroupPartialLine = nil
            applyLiveOutputEffects(liveOutputPolicy.cancelPending())
            return update
        }

        alternateScreenLines = []
        if establishesBaseline {
            seedConversation(from: update.snapshot)
        } else {
            apply(update.events)
        }
        return update
    }

    /// Sends text unchanged as UTF-8, followed by the terminal Return byte.
    func submitInput(_ text: String) async {
        await sendCommand(text)
    }

    func submitInputText() async {
        await sendCommand(inputText)
    }

    func clearInput() {
        inputText = ""
    }

    /// Repeats an outbound command through the same byte-exact terminal path.
    func runAgain(commandID: UUID) async {
        guard let command = conversationEntries.first(where: { $0.id == commandID && $0.isCommand }) else {
            return
        }
        await sendCommand(command.text)
    }

    /// Invokes one configured control through the existing terminal session.
    func send(control: TerminalControlKey) async {
        guard let session else {
            lastInputError = "Terminal is not connected."
            requestFeedback(.error)
            return
        }
        switch TerminalControlChordEncoder.encode(control.chord) {
        case .failure(let error):
            lastInputError = error.explanation
            requestFeedback(.error)
            return
        case .success(let bytes):
            do {
                try await session.sendTerminalInput(bytes)
                lastInputError = nil
                requestFeedback(.selectionAccepted)
            } catch {
                lastInputError = error.localizedDescription
                requestFeedback(.error)
            }
        }
    }

    /// Resolves a configured control by its stable action ID. List position and
    /// display name are deliberately not part of invocation.
    func send(controlID: String, from controls: [TerminalControlKey]) async {
        guard let control = controls.first(where: { $0.id == controlID }) else {
            lastInputError = "This Control Key is no longer available."
            requestFeedback(.error)
            return
        }
        await send(control: control)
    }

    func performCopy(for entryID: UUID) -> Bool {
        guard let entry = conversationEntries.first(where: { $0.id == entryID }) else {
            return false
        }
        copyToClipboard(ConversationAccessibilityActionPolicy.copyText(for: entry))
        requestFeedback(.copied)
        return true
    }

    func performCopyAll(from snapshot: AccessibleConversationSnapshot) {
        copyToClipboard(ConversationAccessibilityActionPolicy.copyAllText(for: snapshot))
        requestFeedback(.copied)
    }

    /// User-facing Snapshot capture. Unlike `captureSnapshot(for:)`, this
    /// records interaction feedback for an explicit Open Snapshot action.
    func performOpenSnapshot(for entryID: UUID) -> AccessibleConversationSnapshot? {
        guard let snapshot = captureSnapshot(for: entryID) else { return nil }
        requestFeedback(.selectionAccepted)
        return snapshot
    }

    private func sendCommand(_ text: String) async {
        guard !isSubmittingInput else { return }
        isSubmittingInput = true
        defer { isSubmittingInput = false }
        let returnBytes: Data
        switch TerminalControlChordEncoder.encode(.returnKey) {
        case .success(let bytes):
            returnBytes = bytes
        case .failure(let error):
            lastInputError = error.explanation
            requestFeedback(.error)
            return
        }

        guard let session else {
            lastInputError = "Terminal is not connected."
            requestFeedback(.error)
            return
        }
        finalizeOpenOutputGroupForNewCommand()
        let previousOutbound = lastOutboundCommandText
        let entry = text.isEmpty
            ? nil
            : AccessibleConversationEntry(text: text, role: .outboundCommand)
        if let entry {
            conversationEntries.append(entry)
            lastOutboundCommandText = text
        }
        do {
            if !text.isEmpty {
                try await session.sendTerminalInput(Data(text.utf8))
            }
            try await session.sendTerminalInput(returnBytes)
            inputText = ""
            lastInputError = nil
            requestFeedback(.selectionAccepted)
        } catch {
            if let entry {
                conversationEntries.removeAll { $0.id == entry.id }
            }
            lastOutboundCommandText = previousOutbound
            lastInputError = error.localizedDescription
            requestFeedback(.error)
        }
    }

    /// Presentation does not infer geometry. A caller with explicit terminal
    /// dimensions may request the existing local-then-remote resize behavior.
    func resize(columns: Int, rows: Int) async {
        guard let session else {
            lastInputError = "Terminal is not connected."
            requestFeedback(.error)
            return
        }
        do {
            try await session.resizeTerminal(columns: columns, rows: rows)
            lastInputError = nil
            refresh()
        } catch {
            lastInputError = error.localizedDescription
            requestFeedback(.error)
        }
    }

    /// Keeps transcript labels content-first; heading semantics are applied by
    /// the native SwiftUI command entry view.
    func accessibilityLabel(for entry: AccessibleConversationEntry) -> String {
        entry.isCompactLargeOutput ? entry.presentationText : entry.accessibilityText
    }

    func accessibilityActions(for entry: AccessibleConversationEntry) -> [ConversationAccessibilityAction] {
        ConversationAccessibilityActionPolicy.actions(for: entry, preferences: voiceOverActionPreferences)
    }

    func inputAccessibilityActions() -> [ConversationAccessibilityAction] {
        ConversationAccessibilityActionPolicy.inputActions(inputText: inputText)
    }

    func setLiveOutputVoiceOverEnabled(_ isEnabled: Bool) {
        liveOutputContext.isVoiceOverEnabled = isEnabled
        dynamicReadingContext.isVoiceOverEnabled = isEnabled
        refreshLiveOutputContext()
    }

    func setDynamicReadingEnabled(_ isEnabled: Bool) {
        dynamicReadingContext.enabled = isEnabled
        if !isEnabled { pendingDynamicReadingAnnouncements.removeAll() }
    }

    func setVoiceOverActionPreferences(_ preferences: VoiceOverActionPreferences) {
        voiceOverActionPreferences = preferences
    }

    func consumeDynamicReadingAnnouncements() -> [DynamicReadingAnnouncement] {
        let announcements = pendingDynamicReadingAnnouncements
        pendingDynamicReadingAnnouncements.removeAll()
        return announcements
    }

    /// Ends editing without discarding the user's text.
    func endEditingSession() {
        focusedConversationEntryID = nil
        liveOutputContext.isInputFocused = false
    }

    func setLiveOutputFocusedConversationEntryID(_ entryID: UUID?) {
        focusedConversationEntryID = entryID
        refreshLiveOutputContext()
    }

    func setLiveOutputInputFocused(_ isFocused: Bool) {
        liveOutputContext.isInputFocused = isFocused
        refreshLiveOutputContext()
    }

    func setLiveOutputSnapshotInspecting(_ isInspecting: Bool) {
        liveOutputContext.isSnapshotInspecting = isInspecting
        refreshLiveOutputContext()
    }

    /// Freezes one incoming conversation entry for stable, document-like
    /// inspection. This never changes the live terminal conversation.
    func captureSnapshot(for entryID: UUID) -> AccessibleConversationSnapshot? {
        guard let entry = conversationEntries.first(where: { $0.id == entryID }),
              entry.role == .incomingContent else {
            return nil
        }
        return AccessibleConversationSnapshot(sourceEntryID: entry.id, text: entry.text)
    }

    private func seedConversation(from snapshot: AccessibleTerminalSnapshot) {
        let lines = usefulLines(in: snapshot)
        let completed = lines.filter { !$0.containsCursor }
        _ = ingestCompletedLines(completed)
        if let current = lines.first(where: \.containsCursor) {
            _ = ingestCurrentLine(current)
        }
    }

    private func apply(_ events: [TerminalAccessibilityEvent]) {
        var receivedIncomingContent = false
        for event in events {
            switch event {
            case .completedLinesAppended(let lines):
                let ingested = ingestCompletedLines(lines)
                var finalized = ingested.finalizedEntries
                if let openGroup = ingested.openGroup {
                    finalized.append(openGroup)
                }
                if !finalized.isEmpty {
                    receivedIncomingContent = true
                }
                announceFinalized(finalized)
            case .currentLineChanged(let line):
                if let entry = ingestCurrentLine(line) {
                    receivedIncomingContent = true
                    announceStreamingIfNeeded(entry)
                } else {
                    applyLiveOutputEffects(liveOutputPolicy.cancelPending())
                }
            case .screenReplaced, .alternateScreenEntered, .alternateScreenExited:
                // Repaints and alternate-screen transitions are display state,
                // not append-only conversation history.
                streamingEntryID = nil
                openOutputEntryID = nil
                openGroupPartialLine = nil
                applyLiveOutputEffects(liveOutputPolicy.cancelPending())
            case .cursorMoved, .shellIntegrationMarksAppeared:
                break
            }
        }
        if receivedIncomingContent {
            onIncomingConversationContent?()
        }
    }

    private func ingestCompletedLines(_ lines: [AccessibleTerminalLine]) -> CompletedLineIngest {
        var result = CompletedLineIngest()
        for line in lines where isUseful(line) {
            if isProvenCommandEcho(line) {
                continue
            }
            if isPromptOnly(line) {
                shellPromptContext = line.text
                result.openGroup = nil
                if let finalized = finalizeOpenOutputGroup() {
                    result.finalizedEntries.append(finalized)
                }
                continue
            }
            if hasOutputSemantics(line) {
                result.openGroup = appendCompletedOutput(line.text)
                continue
            }
            if let finalized = finalizeOpenOutputGroup() {
                result.finalizedEntries.append(finalized)
            }
            result.openGroup = nil
            result.finalizedEntries.append(contentsOf: appendFallbackCompleted(line))
        }
        return result
    }

    private func ingestCurrentLine(_ line: AccessibleTerminalLine) -> AccessibleConversationEntry? {
        guard isUseful(line) else {
            streamingEntryID = nil
            return nil
        }
        if isProvenCommandEcho(line) {
            return nil
        }
        if isPromptOnly(line) {
            shellPromptContext = line.text
            _ = finalizeOpenOutputGroup()
            return nil
        }
        if hasOutputSemantics(line) {
            return applyCurrentOutputLine(line.text)
        }
        if openOutputEntryID != nil {
            _ = finalizeOpenOutputGroup()
        }
        return updateStreamingContent(with: line)
    }

    private func appendCompletedOutput(_ text: String) -> AccessibleConversationEntry {
        if openGroupPartialLine == text {
            openGroupPartialLine = nil
            if let openOutputEntryID,
               let index = conversationEntries.firstIndex(where: { $0.id == openOutputEntryID }) {
                return conversationEntries[index]
            }
        }
        return appendOutputLine(text)
    }

    private func applyCurrentOutputLine(_ text: String) -> AccessibleConversationEntry {
        if let openOutputEntryID,
           let index = conversationEntries.firstIndex(where: { $0.id == openOutputEntryID }) {
            let base = baseTextRemovingPartial(conversationEntries[index].text)
            conversationEntries[index].text = base.isEmpty ? text : base + "\n" + text
            openGroupPartialLine = text
            streamingEntryID = openOutputEntryID
            return conversationEntries[index]
        }
        let entry = appendOutputLine(text)
        openGroupPartialLine = text
        return entry
    }

    private func appendOutputLine(_ text: String) -> AccessibleConversationEntry {
        if let openOutputEntryID,
           let index = conversationEntries.firstIndex(where: { $0.id == openOutputEntryID }) {
            if conversationEntries[index].text.isEmpty {
                conversationEntries[index].text = text
            } else {
                conversationEntries[index].text += "\n" + text
            }
            streamingEntryID = openOutputEntryID
            return conversationEntries[index]
        }
        let entry = AccessibleConversationEntry(text: text, role: .incomingContent)
        conversationEntries.append(entry)
        openOutputEntryID = entry.id
        streamingEntryID = entry.id
        return entry
    }

    private func appendFallbackCompleted(_ line: AccessibleTerminalLine) -> [AccessibleConversationEntry] {
        if let streamingEntryID,
           let index = conversationEntries.firstIndex(where: { $0.id == streamingEntryID }),
           conversationEntries[index].text == line.text {
            self.streamingEntryID = nil
            return [conversationEntries[index]]
        }
        let entry = AccessibleConversationEntry(text: line.text, role: .incomingContent)
        conversationEntries.append(entry)
        return [entry]
    }

    private func updateStreamingContent(with line: AccessibleTerminalLine) -> AccessibleConversationEntry? {
        guard isUseful(line) else {
            streamingEntryID = nil
            return nil
        }

        if let streamingEntryID,
           let index = conversationEntries.firstIndex(where: { $0.id == streamingEntryID }) {
            conversationEntries[index].text = line.text
            return conversationEntries[index]
        }

        let entry = AccessibleConversationEntry(text: line.text, role: .incomingContent)
        conversationEntries.append(entry)
        streamingEntryID = entry.id
        return entry
    }

    @discardableResult
    private func finalizeOpenOutputGroup() -> AccessibleConversationEntry? {
        guard let id = openOutputEntryID,
              let entry = conversationEntries.first(where: { $0.id == id }) else {
            openOutputEntryID = nil
            openGroupPartialLine = nil
            return nil
        }
        openOutputEntryID = nil
        openGroupPartialLine = nil
        if streamingEntryID == id {
            streamingEntryID = nil
        }
        return entry
    }

    private func finalizeOpenOutputGroupForNewCommand() {
        if let finalized = finalizeOpenOutputGroup() {
            announceFinalized([finalized])
        }
    }

    private func baseTextRemovingPartial(_ text: String) -> String {
        guard let openGroupPartialLine else { return text }
        if text == openGroupPartialLine {
            return ""
        }
        let suffix = "\n" + openGroupPartialLine
        if text.hasSuffix(suffix) {
            return String(text.dropLast(suffix.count))
        }
        return text
    }

    private func hasOutputSemantics(_ line: AccessibleTerminalLine) -> Bool {
        line.shellSemanticContent.contains(.output)
    }

    private func isPromptOnly(_ line: AccessibleTerminalLine) -> Bool {
        let content = line.shellSemanticContent
        if !content.isEmpty {
            return content.allSatisfy { item in
                if case .prompt = item { return true }
                return false
            }
        }
        // No-OSC shells do not provide semantic marks. Recognize only the
        // narrow, conventional prompt suffix so it stays context instead of
        // becoming the primary spoken response; raw terminal text is intact.
        let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 160 else { return false }
        return trimmed.range(of: #"^[^\r\n]+\s[>$#]$"#, options: .regularExpression) != nil
    }

    private func isProvenCommandEcho(_ line: AccessibleTerminalLine) -> Bool {
        guard let lastOutboundCommandText,
              line.text == lastOutboundCommandText,
              line.shellSemanticContent.contains(.input),
              !line.shellSemanticContent.contains(.output) else {
            return false
        }
        return true
    }

    private func announceStreamingIfNeeded(_ entry: AccessibleConversationEntry) {
        // Mutable current lines are coalesced into the finalized semantic
        // response. This avoids byte/line chatter without timing sleeps.
    }

    private func announceFinalized(_ entries: [AccessibleConversationEntry]) {
        for entry in entries where shouldAnnounce(entry) {
            dynamicReadingQueue.enqueue(
                entryID: entry.id,
                sessionID: sessionID,
                text: entry.liveAnnouncementText,
                context: currentDynamicReadingContext()
            )
        }
        pendingDynamicReadingAnnouncements.append(contentsOf: dynamicReadingQueue.drain())
    }

    private func shouldAnnounce(_ entry: AccessibleConversationEntry) -> Bool {
        guard entry.isCompactLargeOutput else { return true }
        if announcedLargeOutputIDs.contains(entry.id) {
            return false
        }
        announcedLargeOutputIDs.insert(entry.id)
        return true
    }

    private func usefulLines(in snapshot: AccessibleTerminalSnapshot) -> [AccessibleTerminalLine] {
        snapshot.lines.filter(isUseful)
    }

    private func isUseful(_ line: AccessibleTerminalLine) -> Bool {
        !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateSessionState(_ state: TerminalPresentationSessionState) {
        sessionState = state
    }

    private func requestFeedback(_ kind: InteractionFeedbackKind) {
        lastInteractionFeedback = InteractionFeedbackRequest(kind: kind)
    }

    private func resetPresentation() {
        observationGeneration &+= 1
        accessibilityModel = TerminalAccessibilityModel()
        accessibleSnapshot = nil
        conversationEntries = []
        alternateScreenLines = []
        streamingEntryID = nil
        openOutputEntryID = nil
        openGroupPartialLine = nil
        lastOutboundCommandText = nil
        shellPromptContext = nil
        announcedLargeOutputIDs = []
        lastInputError = nil
        lastInteractionFeedback = nil
        focusedConversationEntryID = nil
        liveOutputAnnouncement = nil
        pendingDynamicReadingAnnouncements.removeAll()
        sessionID = UUID()
        dynamicReadingQueue.reset()
        applyLiveOutputEffects(liveOutputPolicy.reset())
    }

    private func currentLiveOutputContext() -> LiveOutputAnnouncementContext {
        var context = liveOutputContext
        let latestIncomingID = conversationEntries.last(where: { $0.role == .incomingContent })?.id
        context.isReadingHistory = focusedConversationEntryID != nil
            && focusedConversationEntryID != latestIncomingID
        return context
    }

    private func currentDynamicReadingContext() -> DynamicReadingContext {
        var context = dynamicReadingContext
        let latestIncomingID = conversationEntries.last(where: { $0.role == .incomingContent })?.id
        context.isReadingHistory = focusedConversationEntryID != nil
            && focusedConversationEntryID != latestIncomingID
        return context
    }

    private func refreshLiveOutputContext() {
        applyLiveOutputEffects(liveOutputPolicy.updateContext(currentLiveOutputContext()))
    }

    private func applyLiveOutputEffects(_ effects: [LiveOutputAnnouncementPolicyEffect]) {
        for effect in effects {
            switch effect {
            case .announce(let announcement):
                liveOutputAnnouncement = announcement
            case .schedule(let schedule):
                liveOutputAnnouncementTask?.cancel()
                liveOutputAnnouncementTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: schedule.delay)
                    } catch {
                        return
                    }
                    guard let self, !Task.isCancelled else { return }
                    self.applyLiveOutputEffects(self.liveOutputPolicy.settle(
                        token: schedule.token,
                        context: self.currentLiveOutputContext()
                    ))
                }
            case .cancelScheduled:
                liveOutputAnnouncementTask?.cancel()
                liveOutputAnnouncementTask = nil
            }
        }
    }
}

extension SSHTerminalSession: TerminalPresentationSession {
    var terminalPresentationSnapshot: TerminalSnapshot {
        snapshot()
    }

    var terminalPresentationState: TerminalPresentationSessionState {
        switch state {
        case .idle:
            .connecting
        case .running:
            .connected
        case .ended:
            .ended
        case .closed:
            .closed
        case .failed(let message):
            .failed(message)
        }
    }

    func sendTerminalInput(_ bytes: Data) async throws {
        try await send(bytes)
    }

    func resizeTerminal(columns: Int, rows: Int) async throws {
        try await resize(columns: columns, rows: rows)
    }
}
