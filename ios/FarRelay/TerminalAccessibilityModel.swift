import Foundation

/// One logical line derived from one or more terminal buffer rows.
///
/// `logicalIndex` is stable only within this snapshot. Terminal reflow can
/// legitimately change physical row boundaries, so callers must not persist it
/// as a cross-snapshot identity.
public struct AccessibleTerminalLine: Equatable, Sendable {
    public let logicalIndex: Int
    public let text: String
    public let physicalRowCount: Int
    public let containsCursor: Bool
    /// Scrollback row coordinates are stable only until terminal reflow
    /// or scrollback trimming changes the underlying buffer.
    public let scrollbackRows: [Int]
    /// OSC 133 roles already parsed by `TerminalEngine`; no escape sequences
    /// are parsed again here.
    public let shellSemanticContent: [TerminalShellSemanticContent]
    public let shellIntegrationMarks: [TerminalShellIntegrationMark]

    public var isSoftWrapped: Bool {
        physicalRowCount > 1
    }

    public init(
        logicalIndex: Int,
        text: String,
        physicalRowCount: Int,
        containsCursor: Bool,
        scrollbackRows: [Int] = [],
        shellSemanticContent: [TerminalShellSemanticContent] = [],
        shellIntegrationMarks: [TerminalShellIntegrationMark] = []
    ) {
        self.logicalIndex = logicalIndex
        self.text = text
        self.physicalRowCount = physicalRowCount
        self.containsCursor = containsCursor
        self.scrollbackRows = scrollbackRows
        self.shellSemanticContent = shellSemanticContent
        self.shellIntegrationMarks = shellIntegrationMarks
    }
}

/// Immutable terminal information intended for assistive presentation.
public struct AccessibleTerminalSnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let dimensions: TerminalDimensions
    public let cursor: TerminalCursor
    public let lines: [AccessibleTerminalLine]
    public let viewportLogicalLineIndices: [Int]
    public let isAlternateScreen: Bool
    public let shellIntegrationMarks: [TerminalShellIntegrationMark]

    public var visibleLines: [AccessibleTerminalLine] {
        viewportLogicalLineIndices.compactMap { lines.indices.contains($0) ? lines[$0] : nil }
    }

    public var currentLine: AccessibleTerminalLine? {
        lines.first(where: \.containsCursor)
    }
}

/// Semantic changes that a future assistive presenter may announce, coalesce,
/// or expose for navigation. These are not speech commands.
public enum TerminalAccessibilityEvent: Equatable, Sendable {
    /// One or more logical lines completed since the previous snapshot.
    case completedLinesAppended([AccessibleTerminalLine])
    /// The mutable line containing the cursor changed; presenters may coalesce
    /// these while text arrives one byte at a time.
    case currentLineChanged(AccessibleTerminalLine)
    case cursorMoved(TerminalCursor)
    /// A parsed OSC 133 prompt mark appeared. Its shell-supplied kind is
    /// preserved, but no command boundary is inferred from it.
    case shellIntegrationMarksAppeared([TerminalShellIntegrationMark])
    case alternateScreenEntered
    case alternateScreenExited
    /// Terminal content changed in a way that is not an append or current-line
    /// edit, including reflow and alternate-screen repainting.
    case screenReplaced
}

/// One deterministic interpretation result from a terminal snapshot.
public struct TerminalAccessibilityUpdate: Equatable, Sendable {
    public let snapshot: AccessibleTerminalSnapshot
    public let events: [TerminalAccessibilityEvent]
}

/// Interprets immutable terminal snapshots for future assistive presentation.
///
/// Parsing, SSH, UI, and speech remain outside this type. The straightforward
/// comparison is O(number of logical lines) per distinct terminal revision;
/// it deliberately favors trustworthy semantics over a generalized diff cache.
@MainActor
public final class TerminalAccessibilityModel {
    public private(set) var accessibleSnapshot: AccessibleTerminalSnapshot?

    public init() {}

    /// Establishes an initial baseline without replaying existing history as
    /// announcements. Reprocessing the same revision is idempotent.
    public func process(_ terminalSnapshot: TerminalSnapshot) -> TerminalAccessibilityUpdate {
        let current = makeAccessibleSnapshot(from: terminalSnapshot)
        guard let previous = accessibleSnapshot else {
            accessibleSnapshot = current
            return TerminalAccessibilityUpdate(snapshot: current, events: [])
        }
        guard current.revision != previous.revision else {
            return TerminalAccessibilityUpdate(snapshot: current, events: [])
        }

        let events = deriveEvents(from: previous, to: current)
        accessibleSnapshot = current
        return TerminalAccessibilityUpdate(snapshot: current, events: events)
    }

    private func makeAccessibleSnapshot(from snapshot: TerminalSnapshot) -> AccessibleTerminalSnapshot {
        let physicalLines = snapshot.scrollback + snapshot.viewport
        let firstViewportRow = snapshot.scrollback.count
        let cursorPhysicalRow = firstViewportRow + snapshot.cursor.row
        let marksByRow = Dictionary(grouping: snapshot.shellIntegrationMarks, by: \.row)
        var lines: [AccessibleTerminalLine] = []
        var viewportLogicalLineIndices: [Int] = []

        for (physicalRow, physicalLine) in physicalLines.enumerated() {
            let containsCursor = physicalRow == cursorPhysicalRow
            let belongsToViewport = physicalRow >= firstViewportRow
            if physicalLine.isWrappedContinuation, var previous = lines.last {
                previous = AccessibleTerminalLine(
                    logicalIndex: previous.logicalIndex,
                    text: previous.text + physicalLine.text,
                    physicalRowCount: previous.physicalRowCount + 1,
                    containsCursor: previous.containsCursor || containsCursor,
                    scrollbackRows: previous.scrollbackRows + [physicalLine.scrollbackRow],
                    shellSemanticContent: unique(
                        previous.shellSemanticContent + physicalLine.shellSemanticContent
                    ),
                    shellIntegrationMarks: previous.shellIntegrationMarks
                        + (marksByRow[physicalLine.scrollbackRow] ?? [])
                )
                lines[lines.count - 1] = previous
                if belongsToViewport,
                   viewportLogicalLineIndices.last != previous.logicalIndex {
                    viewportLogicalLineIndices.append(previous.logicalIndex)
                }
                continue
            }

            let line = AccessibleTerminalLine(
                logicalIndex: lines.count,
                text: physicalLine.text,
                physicalRowCount: 1,
                containsCursor: containsCursor,
                scrollbackRows: [physicalLine.scrollbackRow],
                shellSemanticContent: physicalLine.shellSemanticContent,
                shellIntegrationMarks: marksByRow[physicalLine.scrollbackRow] ?? []
            )
            lines.append(line)
            if belongsToViewport {
                viewportLogicalLineIndices.append(line.logicalIndex)
            }
        }

        return AccessibleTerminalSnapshot(
            revision: snapshot.revision,
            dimensions: snapshot.dimensions,
            cursor: snapshot.cursor,
            lines: lines,
            viewportLogicalLineIndices: viewportLogicalLineIndices,
            isAlternateScreen: snapshot.isAlternateScreen,
            shellIntegrationMarks: snapshot.shellIntegrationMarks
        )
    }

    private func deriveEvents(
        from previous: AccessibleTerminalSnapshot,
        to current: AccessibleTerminalSnapshot
    ) -> [TerminalAccessibilityEvent] {
        guard previous.isAlternateScreen == current.isAlternateScreen else {
            return alternateScreenTransitionEvents(
                from: previous.isAlternateScreen,
                to: current.isAlternateScreen
            )
        }

        if current.isAlternateScreen {
            return previous.lines == current.lines ? [] : [.screenReplaced]
        }

        if previous.dimensions != current.dimensions {
            return [.screenReplaced]
        }

        var events: [TerminalAccessibilityEvent] = []
        let previousCompletedLines = completedLines(in: previous)
        let currentCompletedLines = completedLines(in: current)

        if currentCompletedLines.starts(with: previousCompletedLines) {
            let appended = Array(currentCompletedLines.dropFirst(previousCompletedLines.count))
            if !appended.isEmpty {
                events.append(.completedLinesAppended(appended))
            }
            appendCurrentLineAndCursorEvents(
                from: previous,
                to: current,
                into: &events
            )
        } else if previous.lines != current.lines {
            events.append(.screenReplaced)
        } else if previous.cursor != current.cursor {
            events.append(.cursorMoved(current.cursor))
        }

        let previousMarks = Set(previous.shellIntegrationMarks)
        let newMarks = current.shellIntegrationMarks.filter { !previousMarks.contains($0) }
        if !newMarks.isEmpty {
            events.append(.shellIntegrationMarksAppeared(newMarks))
        }
        return events
    }

    private func completedLines(in snapshot: AccessibleTerminalSnapshot) -> [AccessibleTerminalLine] {
        snapshot.lines.filter { !$0.containsCursor && !$0.text.isEmpty }
    }

    private func appendCurrentLineAndCursorEvents(
        from previous: AccessibleTerminalSnapshot,
        to current: AccessibleTerminalSnapshot,
        into events: inout [TerminalAccessibilityEvent]
    ) {
        if let currentLine = current.currentLine,
           !currentLine.text.isEmpty,
           currentLine != previous.currentLine {
            events.append(.currentLineChanged(currentLine))
        }
        if previous.cursor != current.cursor {
            events.append(.cursorMoved(current.cursor))
        }
    }

    private func alternateScreenTransitionEvents(
        from wasAlternateScreen: Bool,
        to isAlternateScreen: Bool
    ) -> [TerminalAccessibilityEvent] {
        if isAlternateScreen {
            return [.alternateScreenEntered, .screenReplaced]
        }
        if wasAlternateScreen {
            return [.alternateScreenExited, .screenReplaced]
        }
        return []
    }

    private func unique(_ content: [TerminalShellSemanticContent]) -> [TerminalShellSemanticContent] {
        content.reduce(into: []) { result, item in
            if !result.contains(item) {
                result.append(item)
            }
        }
    }
}
