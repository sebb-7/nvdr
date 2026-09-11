import Foundation
import SwiftTerm

enum TerminalEngineError: LocalizedError, Equatable, Sendable {
    case nonPositiveColumns
    case nonPositiveRows
    case negativeScrollbackLimit

    var errorDescription: String? {
        switch self {
        case .nonPositiveColumns: return "Terminal columns must be greater than zero."
        case .nonPositiveRows: return "Terminal rows must be greater than zero."
        case .negativeScrollbackLimit: return "Terminal scrollback limit must not be negative."
        }
    }
}

struct TerminalDimensions: Sendable, Equatable {
    let columns: Int
    let rows: Int

    static let standard = TerminalDimensions(validatedColumns: 80, rows: 24)

    init(columns: Int, rows: Int) throws {
        guard columns > 0 else { throw TerminalEngineError.nonPositiveColumns }
        guard rows > 0 else { throw TerminalEngineError.nonPositiveRows }
        self.columns = columns
        self.rows = rows
    }

    fileprivate init(validatedColumns columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

struct TerminalCursor: Sendable, Equatable {
    let column: Int
    let row: Int
}

struct TerminalLineSnapshot: Sendable, Equatable {
    let text: String
    let isWrapped: Bool
}

/// A renderer-independent value view of SwiftTerm's active screen buffer.
///
/// `viewport` reflects the currently visible rows. `scrollback` contains the
/// retained lines before that viewport, and is empty while the alternate
/// screen is active because SwiftTerm intentionally gives it no history.
struct TerminalSnapshot: Sendable, Equatable {
    let dimensions: TerminalDimensions
    let cursor: TerminalCursor
    let viewport: [TerminalLineSnapshot]
    let scrollback: [TerminalLineSnapshot]
    let isAlternateScreen: Bool
    let revision: UInt64
}

/// Owns a SwiftTerm parser without creating a UIKit, SwiftUI, or Metal view.
///
/// SwiftTerm's mutable terminal core is not Sendable. Main-actor isolation
/// confines parser mutation and snapshot extraction to one executor while the
/// returned snapshot remains safe to transfer to a future renderer.
@MainActor
final class TerminalEngine {
    private let delegate = TerminalEngineDelegate()
    private let terminal: Terminal
    private var revision: UInt64 = 0

    init(
        dimensions: TerminalDimensions = .standard,
        scrollbackLimit: Int = 1_000
    ) throws {
        guard scrollbackLimit >= 0 else { throw TerminalEngineError.negativeScrollbackLimit }
        terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(
                cols: dimensions.columns,
                rows: dimensions.rows,
                scrollback: scrollbackLimit
            )
        )
    }

    /// Parses exactly the supplied bytes. Chunks may split UTF-8 scalars or
    /// ANSI escape sequences; SwiftTerm retains parser state across calls.
    @discardableResult
    func ingest(_ bytes: Data) -> TerminalSnapshot {
        terminal.feed(byteArray: Array(bytes))
        revision &+= 1
        return snapshot()
    }

    /// Updates the terminal model's cell geometry without involving a view.
    @discardableResult
    func resize(columns: Int, rows: Int) throws -> TerminalSnapshot {
        _ = try TerminalDimensions(columns: columns, rows: rows)
        terminal.resize(cols: columns, rows: rows)
        revision &+= 1
        return snapshot()
    }

    func snapshot() -> TerminalSnapshot {
        let allLines = invariantLines()
        let viewport = (0..<terminal.rows).compactMap { row in
            terminal.getLine(row: row).map(snapshotLine)
        }
        let historyCount = max(0, allLines.count - viewport.count)

        return TerminalSnapshot(
            dimensions: TerminalDimensions(validatedColumns: terminal.cols, rows: terminal.rows),
            cursor: TerminalCursor(column: terminal.buffer.x, row: terminal.buffer.y),
            viewport: viewport,
            scrollback: Array(allLines.prefix(historyCount)),
            isAlternateScreen: terminal.isCurrentBufferAlternate,
            revision: revision
        )
    }

    private func invariantLines() -> [TerminalLineSnapshot] {
        var lines: [TerminalLineSnapshot] = []
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            lines.append(snapshotLine(line))
            row += 1
        }
        return lines
    }

    private func snapshotLine(_ line: BufferLine) -> TerminalLineSnapshot {
        TerminalLineSnapshot(
            text: line.translateToString(
                trimRight: true,
                skipNullCellsFollowingWide: true,
                characterProvider: { [terminal] charData in terminal.getCharacter(for: charData) }
            ).replacing("\u{0}", with: " "),
            isWrapped: line.isWrapped
        )
    }
}

/// SwiftTerm supplies defaults for every delegate callback. Keeping this
/// delegate intentionally inert proves that `Terminal` can be used as a pure
/// parser/state engine, independently from its Apple terminal views.
private final class TerminalEngineDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    func isProcessTrusted(source: Terminal) -> Bool { false }
}
