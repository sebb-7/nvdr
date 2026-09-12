import Foundation
import Observation

/// User-facing lifecycle information for an interactive terminal.
public enum TerminalPresentationSessionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case ended
    case failed(String)
    case closed

    public var accessibilityLabel: String {
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

/// The small set of terminal control bytes exposed by the first presentation.
public enum TerminalPresentationAction: CaseIterable, Identifiable, Sendable {
    case returnKey
    case escape
    case tab
    case backspace
    case upArrow
    case downArrow
    case rightArrow
    case leftArrow
    case interrupt
    case endOfTransmission

    public var id: String { title }

    public var title: String {
        switch self {
        case .returnKey: "Return"
        case .escape: "Escape"
        case .tab: "Tab"
        case .backspace: "Backspace"
        case .upArrow: "Up Arrow"
        case .downArrow: "Down Arrow"
        case .rightArrow: "Right Arrow"
        case .leftArrow: "Left Arrow"
        case .interrupt: "Control-C"
        case .endOfTransmission: "Control-D"
        }
    }

    public var inputBytes: Data {
        switch self {
        case .returnKey: Data([0x0D])
        case .escape: Data([0x1B])
        case .tab: Data([0x09])
        case .backspace: Data([0x7F])
        case .upArrow: Data("\u{1B}[A".utf8)
        case .downArrow: Data("\u{1B}[B".utf8)
        case .rightArrow: Data("\u{1B}[C".utf8)
        case .leftArrow: Data("\u{1B}[D".utf8)
        case .interrupt: Data([0x03])
        case .endOfTransmission: Data([0x04])
        }
    }
}

/// The presentation-facing terminal capability. This deliberately excludes
/// SSH transport, terminal-parser, and UI implementation details.
@MainActor
public protocol TerminalPresentationSession: AnyObject {
    var terminalPresentationSnapshot: TerminalSnapshot { get }
    var terminalPresentationState: TerminalPresentationSessionState { get }
    func observeTerminalPresentationUpdates(
        _ observer: @escaping @MainActor (TerminalSnapshot, TerminalPresentationSessionState) -> Void
    )
    func sendTerminalInput(_ bytes: Data) async throws
    func resizeTerminal(columns: Int, rows: Int) async throws
}

/// UI-facing accessible conversation state derived from terminal semantics.
@Observable
@MainActor
public final class TerminalPresentationModel {
    public private(set) var sessionState: TerminalPresentationSessionState
    public private(set) var accessibleSnapshot: AccessibleTerminalSnapshot?
    public private(set) var conversationEntries: [AccessibleConversationEntry] = []
    public private(set) var alternateScreenLines: [AccessibleTerminalLine] = []
    public private(set) var lastInputError: String?
    public var inputText = ""

    private var accessibilityModel = TerminalAccessibilityModel()
    private var session: (any TerminalPresentationSession)?
    private var streamingEntryID: UUID?
    private var observationGeneration = 0

    public init(session: (any TerminalPresentationSession)? = nil) {
        self.session = session
        sessionState = session?.terminalPresentationState ?? .idle
    }

    /// Starts a new terminal lifetime. A coordinator calls this before it has
    /// a live session to attach, so old history cannot bleed into a new shell.
    public func beginConnecting() {
        session = nil
        sessionState = .connecting
        resetPresentation()
    }

    /// Updates feature-level lifecycle state before a terminal session exists
    /// or after its transport has been released.
    public func setSessionState(_ state: TerminalPresentationSessionState) {
        sessionState = state
    }

    /// Attaches a terminal session owned by a higher-level feature coordinator.
    /// Snapshot updates arrive through the terminal's existing semantic boundary,
    /// rather than by polling terminal text from the SwiftUI view.
    public func attach(_ session: any TerminalPresentationSession) {
        self.session = session
        resetPresentation()
        let generation = observationGeneration
        session.observeTerminalPresentationUpdates { [weak self] snapshot, state in
            guard let self, self.observationGeneration == generation else { return }
            _ = self.process(snapshot, sessionState: state)
        }
        refresh()
    }

    public func refresh() {
        guard let session else { return }
        _ = process(
            session.terminalPresentationSnapshot,
            sessionState: session.terminalPresentationState
        )
    }

    /// Consumes semantic terminal updates without reparsing terminal bytes.
    @discardableResult
    public func process(
        _ terminalSnapshot: TerminalSnapshot,
        sessionState: TerminalPresentationSessionState
    ) -> TerminalAccessibilityUpdate {
        self.sessionState = sessionState
        let establishesBaseline = accessibilityModel.accessibleSnapshot == nil
        let update = accessibilityModel.process(terminalSnapshot)
        accessibleSnapshot = update.snapshot

        if update.snapshot.isAlternateScreen {
            alternateScreenLines = usefulLines(in: update.snapshot)
            streamingEntryID = nil
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
    public func submitInput(_ text: String) async {
        await sendCommand(text)
    }

    public func submitInputText() async {
        await submitInput(inputText)
    }

    /// Repeats an outbound command through the same byte-exact terminal path.
    public func runAgain(commandID: UUID) async {
        guard let command = conversationEntries.first(where: { $0.id == commandID && $0.isCommand }) else {
            return
        }
        await sendCommand(command.text)
    }

    public func send(_ action: TerminalPresentationAction) async {
        guard let session else {
            lastInputError = "Terminal is not connected."
            return
        }
        do {
            try await session.sendTerminalInput(action.inputBytes)
            lastInputError = nil
        } catch {
            lastInputError = error.localizedDescription
        }
    }

    /// Presentation does not infer geometry. A caller with explicit terminal
    /// dimensions may request the existing local-then-remote resize behavior.
    public func resize(columns: Int, rows: Int) async {
        guard let session else {
            lastInputError = "Terminal is not connected."
            return
        }
        do {
            try await session.resizeTerminal(columns: columns, rows: rows)
            lastInputError = nil
            refresh()
        } catch {
            lastInputError = error.localizedDescription
        }
    }

    /// Keeps transcript labels content-first; heading semantics are applied by
    /// the native SwiftUI command entry view.
    public func accessibilityLabel(for entry: AccessibleConversationEntry) -> String {
        entry.text
    }

    /// Freezes one incoming conversation entry for stable, document-like
    /// inspection. This never changes the live terminal conversation.
    public func captureSnapshot(for entryID: UUID) -> AccessibleConversationSnapshot? {
        guard let entry = conversationEntries.first(where: { $0.id == entryID }),
              entry.role == .incomingContent else {
            return nil
        }
        return AccessibleConversationSnapshot(sourceEntryID: entry.id, text: entry.text)
    }

    private func sendCommand(_ text: String) async {
        guard let session else {
            lastInputError = "Terminal is not connected."
            return
        }

        let entry = text.isEmpty
            ? nil
            : AccessibleConversationEntry(text: text, role: .outboundCommand)
        if let entry {
            conversationEntries.append(entry)
        }

        do {
            if !text.isEmpty {
                try await session.sendTerminalInput(Data(text.utf8))
            }
            try await session.sendTerminalInput(TerminalPresentationAction.returnKey.inputBytes)
            inputText = ""
            lastInputError = nil
        } catch {
            if let entry {
                conversationEntries.removeAll { $0.id == entry.id }
            }
            lastInputError = error.localizedDescription
        }
    }

    private func seedConversation(from snapshot: AccessibleTerminalSnapshot) {
        for line in usefulLines(in: snapshot) {
            let entry = AccessibleConversationEntry(text: line.text, role: .incomingContent)
            conversationEntries.append(entry)
            if line.containsCursor {
                streamingEntryID = entry.id
            }
        }
    }

    private func apply(_ events: [TerminalAccessibilityEvent]) {
        for event in events {
            switch event {
            case .completedLinesAppended(let lines):
                appendCompleted(lines)
            case .currentLineChanged(let line):
                updateStreamingContent(with: line)
            case .screenReplaced, .alternateScreenEntered, .alternateScreenExited:
                // Repaints and alternate-screen transitions are display state,
                // not append-only conversation history.
                streamingEntryID = nil
            case .cursorMoved, .shellIntegrationMarksAppeared:
                break
            }
        }
    }

    private func appendCompleted(_ lines: [AccessibleTerminalLine]) {
        for line in lines where isUseful(line) {
            if let streamingEntryID,
               let index = conversationEntries.firstIndex(where: { $0.id == streamingEntryID }),
               conversationEntries[index].text == line.text {
                self.streamingEntryID = nil
                continue
            }
            conversationEntries.append(
                AccessibleConversationEntry(text: line.text, role: .incomingContent)
            )
        }
    }

    private func updateStreamingContent(with line: AccessibleTerminalLine) {
        guard isUseful(line) else {
            streamingEntryID = nil
            return
        }

        if let streamingEntryID,
           let index = conversationEntries.firstIndex(where: { $0.id == streamingEntryID }) {
            conversationEntries[index].text = line.text
            return
        }

        let entry = AccessibleConversationEntry(text: line.text, role: .incomingContent)
        conversationEntries.append(entry)
        streamingEntryID = entry.id
    }

    private func usefulLines(in snapshot: AccessibleTerminalSnapshot) -> [AccessibleTerminalLine] {
        snapshot.lines.filter(isUseful)
    }

    private func isUseful(_ line: AccessibleTerminalLine) -> Bool {
        !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resetPresentation() {
        observationGeneration &+= 1
        accessibilityModel = TerminalAccessibilityModel()
        accessibleSnapshot = nil
        conversationEntries = []
        alternateScreenLines = []
        streamingEntryID = nil
        lastInputError = nil
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
