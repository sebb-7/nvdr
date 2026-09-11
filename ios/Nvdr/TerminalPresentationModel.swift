import Foundation
import Observation

/// Whether presentation follows the terminal cursor or a user-selected line.
public enum TerminalPresentationMode: Equatable, Sendable {
    case live
    case review
}

/// User-facing lifecycle information for an interactive terminal.
public enum TerminalPresentationSessionState: Equatable, Sendable {
    case connecting
    case connected
    case ended
    case failed(String)
    case closed

    public var accessibilityLabel: String {
        switch self {
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
    func sendTerminalInput(_ bytes: Data) async throws
    func resizeTerminal(columns: Int, rows: Int) async throws
}

/// UI-facing terminal state and navigation derived from accessibility snapshots.
@Observable
@MainActor
public final class TerminalPresentationModel {
    public private(set) var sessionState: TerminalPresentationSessionState
    public private(set) var mode: TerminalPresentationMode = .live
    public private(set) var accessibleSnapshot: AccessibleTerminalSnapshot?
    public private(set) var reviewedLogicalLineIndex: Int?
    public private(set) var lastInputError: String?
    public var inputText = ""

    private var accessibilityModel = TerminalAccessibilityModel()
    private var session: (any TerminalPresentationSession)?

    public init(session: (any TerminalPresentationSession)? = nil) {
        self.session = session
        sessionState = session?.terminalPresentationState ?? .connecting
    }

    public var lines: [AccessibleTerminalLine] {
        accessibleSnapshot?.lines ?? []
    }

    public var currentLine: AccessibleTerminalLine? {
        accessibleSnapshot?.currentLine
    }

    public var activeLogicalLineIndex: Int? {
        switch mode {
        case .live:
            currentLine?.logicalIndex ?? lines.last?.logicalIndex
        case .review:
            reviewedLogicalLineIndex
        }
    }

    public var isReviewing: Bool {
        mode == .review
    }

    /// Starts a new terminal lifetime. A coordinator calls this before it has
    /// a live session to attach, so old history cannot bleed into a new shell.
    public func beginConnecting() {
        session = nil
        sessionState = .connecting
        resetPresentation()
    }

    /// Attaches a terminal session owned by a higher-level feature coordinator.
    public func attach(_ session: any TerminalPresentationSession) {
        self.session = session
        resetPresentation()
        refresh()
    }

    public func refresh() {
        guard let session else { return }
        _ = process(
            session.terminalPresentationSnapshot,
            sessionState: session.terminalPresentationState
        )
    }

    /// Consumes a terminal snapshot without requiring a particular SSH client.
    @discardableResult
    public func process(
        _ terminalSnapshot: TerminalSnapshot,
        sessionState: TerminalPresentationSessionState
    ) -> TerminalAccessibilityUpdate {
        self.sessionState = sessionState
        let update = accessibilityModel.process(terminalSnapshot)
        accessibleSnapshot = update.snapshot
        reconcileActiveLine()
        return update
    }

    /// Stops following live cursor movement while retaining the user's chosen
    /// logical line. New output never changes this position automatically.
    public func enterReview(at logicalLineIndex: Int? = nil) {
        guard !lines.isEmpty else { return }
        mode = .review
        reviewedLogicalLineIndex = nearestExistingLine(
            to: logicalLineIndex ?? activeLogicalLineIndex ?? lines[0].logicalIndex
        )
    }

    public func moveReview(by offset: Int) {
        guard !lines.isEmpty else { return }
        enterReview()
        guard let current = reviewedLogicalLineIndex,
              let currentOffset = lines.firstIndex(where: { $0.logicalIndex == current }) else {
            return
        }
        let targetOffset = min(max(currentOffset + offset, 0), lines.count - 1)
        reviewedLogicalLineIndex = lines[targetOffset].logicalIndex
    }

    /// Returns focus-independent navigation to the terminal's current line.
    public func returnToLive() {
        mode = .live
        reviewedLogicalLineIndex = activeLogicalLineIndex
    }

    /// Sends text unchanged as UTF-8, followed by the terminal Return byte.
    public func submitInput(_ text: String) async {
        guard let session else {
            lastInputError = "Terminal is not connected."
            return
        }
        do {
            if !text.isEmpty {
                try await session.sendTerminalInput(Data(text.utf8))
            }
            try await session.sendTerminalInput(TerminalPresentationAction.returnKey.inputBytes)
            inputText = ""
            lastInputError = nil
        } catch {
            lastInputError = error.localizedDescription
        }
    }

    public func submitInputText() async {
        await submitInput(inputText)
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

    public func accessibilityLabel(for line: AccessibleTerminalLine) -> String {
        var components = ["Terminal line \(line.logicalIndex + 1)"]
        if line.logicalIndex == currentLine?.logicalIndex {
            components.append("current line")
        }
        if mode == .review, line.logicalIndex == reviewedLogicalLineIndex {
            components.append("review position")
        }
        components.append(line.text.isEmpty ? "blank" : line.text)
        return components.joined(separator: ", ")
    }

    private func resetPresentation() {
        accessibilityModel = TerminalAccessibilityModel()
        accessibleSnapshot = nil
        mode = .live
        reviewedLogicalLineIndex = nil
        lastInputError = nil
    }

    private func reconcileActiveLine() {
        switch mode {
        case .live:
            reviewedLogicalLineIndex = activeLogicalLineIndex
        case .review:
            if let reviewedLogicalLineIndex {
                self.reviewedLogicalLineIndex = nearestExistingLine(to: reviewedLogicalLineIndex)
            }
        }
    }

    private func nearestExistingLine(to logicalLineIndex: Int) -> Int? {
        lines.min { abs($0.logicalIndex - logicalLineIndex) < abs($1.logicalIndex - logicalLineIndex) }?
            .logicalIndex
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
