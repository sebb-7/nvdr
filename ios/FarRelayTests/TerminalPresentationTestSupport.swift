import Foundation
@testable import FarRelay

struct TerminalSendFailure: Error, LocalizedError {
    var errorDescription: String? { "Terminal is disconnected." }
}

@MainActor
final class FakeTerminalPresentationSession: TerminalPresentationSession {
    var terminalPresentationSnapshot: TerminalSnapshot
    var terminalPresentationState: TerminalPresentationSessionState
    var sendError: (any Error)?
    private(set) var sentBytes: [Data] = []
    private var observer: (@MainActor (TerminalSnapshot, TerminalPresentationSessionState) -> Void)?

    init(state: TerminalPresentationSessionState, snapshot: TerminalSnapshot) {
        terminalPresentationState = state
        terminalPresentationSnapshot = snapshot
    }

    func observeTerminalPresentationUpdates(
        _ observer: @escaping @MainActor (TerminalSnapshot, TerminalPresentationSessionState) -> Void
    ) {
        self.observer = observer
    }

    func sendTerminalInput(_ bytes: Data) async throws {
        if let sendError {
            throw sendError
        }
        sentBytes.append(bytes)
    }

    func resizeTerminal(columns: Int, rows: Int) async throws {}

    func publish(_ snapshot: TerminalSnapshot, state: TerminalPresentationSessionState) {
        terminalPresentationSnapshot = snapshot
        terminalPresentationState = state
        observer?(snapshot, state)
    }
}

enum TerminalPresentationFixtures {
    static let defaultRows = 80

    static func snapshot(
        revision: UInt64,
        viewport: [String],
        cursorRow: Int,
        isAlternateScreen: Bool = false,
        semantics: [[TerminalShellSemanticContent]]? = nil,
        marks: [TerminalShellIntegrationMark] = [],
        rows: Int? = nil,
        columns: Int = 80
    ) -> TerminalSnapshot {
        let rowCount = rows ?? viewport.count
        var paddedViewport = viewport
        var paddedSemantics = semantics ?? Array(repeating: [], count: viewport.count)
        if paddedViewport.count < rowCount {
            paddedViewport.append(contentsOf: Array(repeating: "", count: rowCount - paddedViewport.count))
        }
        if paddedSemantics.count < rowCount {
            paddedSemantics.append(contentsOf: Array(repeating: [], count: rowCount - paddedSemantics.count))
        }
        if paddedViewport.count > rowCount {
            paddedViewport = Array(paddedViewport.prefix(rowCount))
        }
        if paddedSemantics.count > rowCount {
            paddedSemantics = Array(paddedSemantics.prefix(rowCount))
        }
        return TerminalSnapshot(
            revision: revision,
            dimensions: TerminalDimensions(columns: columns, rows: rowCount),
            cursor: TerminalCursor(column: 0, row: cursorRow),
            viewport: zip(paddedViewport, paddedSemantics).map { text, content in
                TerminalLineSnapshot(
                    text: text,
                    isWrappedContinuation: false,
                    shellSemanticContent: content
                )
            },
            scrollback: [],
            isAlternateScreen: isAlternateScreen,
            semanticPromptRows: marks.map(\.row),
            shellIntegrationMarks: marks
        )
    }

    static func empty(revision: UInt64, rows: Int = defaultRows) -> TerminalSnapshot {
        snapshot(
            revision: revision,
            viewport: Array(repeating: "", count: rows),
            cursorRow: 0,
            rows: rows
        )
    }

    static func output(
        revision: UInt64,
        lines: [String],
        rows: Int = defaultRows,
        isAlternateScreen: Bool = false
    ) -> TerminalSnapshot {
        snapshot(
            revision: revision,
            viewport: lines + [""],
            cursorRow: lines.count,
            isAlternateScreen: isAlternateScreen,
            semantics: lines.map { _ in [.output] } + [[]],
            rows: rows
        )
    }
}
