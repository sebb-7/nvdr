import Foundation
import SwiftTerm

public struct TerminalDimensions: Equatable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

public struct TerminalCursor: Equatable, Sendable {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

/// A shell-authored OSC 133 role already parsed by the terminal engine.
public enum TerminalShellSemanticContent: Equatable, Hashable, Sendable {
    case prompt(TerminalShellPromptKind)
    case input
    case output
}

/// The kind supplied by a shell for an OSC 133 prompt mark.
public enum TerminalShellPromptKind: Equatable, Hashable, Sendable {
    case initial
    case right
    case continuation
    case secondary
}

/// A zero-width, shell-authored OSC 133 prompt mark in scrollback coordinates.
public struct TerminalShellIntegrationMark: Equatable, Hashable, Sendable {
    public let row: Int
    public let column: Int
    public let kind: TerminalShellPromptKind

    public init(row: Int, column: Int, kind: TerminalShellPromptKind) {
        self.row = row
        self.column = column
        self.kind = kind
    }
}

public struct TerminalLineSnapshot: Equatable, Sendable {
    public let text: String
    public let isWrappedContinuation: Bool
    public let scrollbackRow: Int
    public let shellSemanticContent: [TerminalShellSemanticContent]

    public init(
        text: String,
        isWrappedContinuation: Bool,
        scrollbackRow: Int = 0,
        shellSemanticContent: [TerminalShellSemanticContent] = []
    ) {
        self.text = text
        self.isWrappedContinuation = isWrappedContinuation
        self.scrollbackRow = scrollbackRow
        self.shellSemanticContent = shellSemanticContent
    }
}

public struct TerminalSnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let dimensions: TerminalDimensions
    public let cursor: TerminalCursor
    public let viewport: [TerminalLineSnapshot]
    public let scrollback: [TerminalLineSnapshot]
    public let isAlternateScreen: Bool
    public let semanticPromptRows: [Int]
    public let shellIntegrationMarks: [TerminalShellIntegrationMark]
}

/// Owns SwiftTerm's mutable parser on the main actor and exposes engine-neutral values.
@MainActor
public final class TerminalEngine {
    private let delegate = TerminalEngineDelegate()
    private let terminal: Terminal
    private var revision: UInt64 = 0

    public init(columns: Int = 80, rows: Int = 24, scrollback: Int = 500) {
        terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: columns, rows: rows, scrollback: scrollback)
        )
    }

    public func feed(_ bytes: Data) {
        terminal.feed(byteArray: Array(bytes))
        revision &+= 1
    }

    public func resize(columns: Int, rows: Int) {
        terminal.resize(cols: columns, rows: rows)
        revision &+= 1
    }

    public func snapshot() -> TerminalSnapshot {
        let scrollbackStart = terminal.buffer.totalLinesTrimmed
        let viewportStart = scrollbackStart + terminal.buffer.yDisp
        var scrollback: [TerminalLineSnapshot] = []
        var semanticPromptRows: [Int] = []
        var shellIntegrationMarks: [TerminalShellIntegrationMark] = []
        var row = scrollbackStart

        while let line = terminal.getScrollInvariantLine(row: row) {
            let bufferRow = row - scrollbackStart
            if row < viewportStart {
                scrollback.append(lineSnapshot(line, bufferRow: bufferRow, scrollbackRow: row))
            }
            let marks = terminal.semanticPromptMarks(at: bufferRow)
            if !marks.isEmpty {
                semanticPromptRows.append(row)
                shellIntegrationMarks += marks.map {
                    TerminalShellIntegrationMark(
                        row: row,
                        column: $0.position.col,
                        kind: shellPromptKind(from: $0.kind)
                    )
                }
            }
            row += 1
        }

        let viewport = (0..<terminal.rows).compactMap { viewportRow -> TerminalLineSnapshot? in
            guard let line = terminal.getLine(row: viewportRow) else { return nil }
            let row = viewportStart + viewportRow
            return lineSnapshot(
                line,
                bufferRow: row - scrollbackStart,
                scrollbackRow: row
            )
        }
        return TerminalSnapshot(
            revision: revision,
            dimensions: TerminalDimensions(columns: terminal.cols, rows: terminal.rows),
            cursor: TerminalCursor(column: terminal.buffer.x, row: terminal.buffer.y),
            viewport: viewport,
            scrollback: scrollback,
            isAlternateScreen: terminal.isCurrentBufferAlternate,
            semanticPromptRows: semanticPromptRows,
            shellIntegrationMarks: shellIntegrationMarks
        )
    }

    private func lineSnapshot(
        _ line: BufferLine,
        bufferRow: Int,
        scrollbackRow: Int
    ) -> TerminalLineSnapshot {
        var semanticContent: [TerminalShellSemanticContent] = []
        for column in 0..<terminal.cols {
            guard let content = terminal.semanticContent(at: Position(col: column, row: bufferRow)),
                  let appContent = shellSemanticContent(from: content),
                  !semanticContent.contains(appContent) else {
                continue
            }
            semanticContent.append(appContent)
        }
        return TerminalLineSnapshot(
            text: line.translateToString(trimRight: true),
            isWrappedContinuation: line.isWrapped,
            scrollbackRow: scrollbackRow,
            shellSemanticContent: semanticContent
        )
    }

    private func shellPromptKind(from kind: SemanticPromptKind) -> TerminalShellPromptKind {
        switch kind {
        case .initial: return .initial
        case .right: return .right
        case .continuation: return .continuation
        case .secondary: return .secondary
        }
    }

    private func shellSemanticContent(from content: SemanticContent) -> TerminalShellSemanticContent? {
        switch content {
        case .none: return nil
        case .prompt(let kind): return .prompt(shellPromptKind(from: kind))
        case .input: return .input
        case .output: return .output
        }
    }
}

private final class TerminalEngineDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
