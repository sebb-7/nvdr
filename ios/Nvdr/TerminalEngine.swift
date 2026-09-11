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

public struct TerminalLineSnapshot: Equatable, Sendable {
    public let text: String
    public let isWrappedContinuation: Bool

    public init(text: String, isWrappedContinuation: Bool) {
        self.text = text
        self.isWrappedContinuation = isWrappedContinuation
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
        var scrollback: [TerminalLineSnapshot] = []
        var semanticPromptRows: [Int] = []
        var row = scrollbackStart

        while let line = terminal.getScrollInvariantLine(row: row) {
            scrollback.append(lineSnapshot(line))
            if !terminal.semanticPromptMarks(at: row).isEmpty {
                semanticPromptRows.append(row)
            }
            row += 1
        }

        let viewport = (0..<terminal.rows).compactMap { terminal.getLine(row: $0) }.map(lineSnapshot)
        return TerminalSnapshot(
            revision: revision,
            dimensions: TerminalDimensions(columns: terminal.cols, rows: terminal.rows),
            cursor: TerminalCursor(column: terminal.buffer.x, row: terminal.buffer.y),
            viewport: viewport,
            scrollback: scrollback,
            isAlternateScreen: terminal.isCurrentBufferAlternate,
            semanticPromptRows: semanticPromptRows
        )
    }

    private func lineSnapshot(_ line: BufferLine) -> TerminalLineSnapshot {
        TerminalLineSnapshot(
            text: line.translateToString(trimRight: true),
            isWrappedContinuation: line.isWrapped
        )
    }
}

private final class TerminalEngineDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
