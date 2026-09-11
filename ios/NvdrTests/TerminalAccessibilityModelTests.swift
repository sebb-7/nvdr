import Foundation
import XCTest
@testable import Nvdr

@MainActor
final class TerminalAccessibilityModelTests: XCTestCase {
    func testCompletedOutputProducesOrderedAccessibleLines() {
        let model = TerminalAccessibilityModel()
        _ = model.process(snapshot(revision: 0, viewport: ["", "", ""], cursorRow: 0))

        let hello = model.process(snapshot(
            revision: 1,
            viewport: ["hello", "", ""],
            cursorRow: 1
        ))
        let world = model.process(snapshot(
            revision: 2,
            viewport: ["hello", "world", ""],
            cursorRow: 2
        ))

        XCTAssertEqual(completedTexts(in: hello.events), ["hello"])
        XCTAssertEqual(completedTexts(in: world.events), ["world"])
        XCTAssertEqual(world.snapshot.lines.map(\.text), ["hello", "world", ""])
        XCTAssertFalse(hello.events.contains { event in
            if case .shellIntegrationMarksAppeared = event { return true }
            return false
        })
    }

    func testChunkBoundariesAndSplitUTF8ProduceEquivalentAccessibleState() {
        let text = "status 🌍"
        let wholeEngine = TerminalEngine(columns: 20, rows: 3)
        let chunkedEngine = TerminalEngine(columns: 20, rows: 3)
        let wholeModel = TerminalAccessibilityModel()
        let chunkedModel = TerminalAccessibilityModel()
        _ = wholeModel.process(wholeEngine.snapshot())
        _ = chunkedModel.process(chunkedEngine.snapshot())

        wholeEngine.feed(Data(text.utf8))
        let whole = wholeModel.process(wholeEngine.snapshot())

        let bytes = Array(text.utf8)
        chunkedEngine.feed(Data(bytes.prefix(8)))
        _ = chunkedModel.process(chunkedEngine.snapshot())
        for byte in bytes.dropFirst(8) {
            chunkedEngine.feed(Data([byte]))
            _ = chunkedModel.process(chunkedEngine.snapshot())
        }

        let chunked = chunkedModel.accessibleSnapshot
        XCTAssertNotEqual(chunked?.revision, whole.snapshot.revision)
        XCTAssertEqual(chunked?.dimensions, whole.snapshot.dimensions)
        XCTAssertEqual(chunked?.cursor, whole.snapshot.cursor)
        XCTAssertEqual(chunked?.lines, whole.snapshot.lines)
        XCTAssertEqual(chunked?.viewportLogicalLineIndices, whole.snapshot.viewportLogicalLineIndices)
        XCTAssertEqual(chunked?.isAlternateScreen, whole.snapshot.isAlternateScreen)
        XCTAssertEqual(chunked?.shellIntegrationMarks, whole.snapshot.shellIntegrationMarks)
        XCTAssertTrue(whole.snapshot.currentLine?.text.contains("🌍") == true)
    }

    func testCurrentLineChangesAreNotCompletedOutputAndAreIdempotent() {
        let model = TerminalAccessibilityModel()
        _ = model.process(snapshot(revision: 0, viewport: ["", ""], cursorRow: 0))

        let typing = snapshot(revision: 1, viewport: ["hello", ""], cursorColumn: 5, cursorRow: 0)
        let typed = model.process(typing)
        let repeated = model.process(typing)
        let completed = model.process(snapshot(
            revision: 2,
            viewport: ["hello", ""],
            cursorRow: 1
        ))

        XCTAssertEqual(completedTexts(in: typed.events), [])
        XCTAssertTrue(typed.events.contains { event in
            if case let .currentLineChanged(line) = event {
                return line.text == "hello"
            }
            return false
        })
        XCTAssertEqual(repeated.events, [])
        XCTAssertEqual(completedTexts(in: completed.events), ["hello"])
    }

    func testSoftWrapJoinsLogicalContentAndResizeIsAScreenReplacement() {
        let engine = TerminalEngine(columns: 4, rows: 3)
        let model = TerminalAccessibilityModel()
        _ = model.process(engine.snapshot())

        engine.feed(Data("abcdE".utf8))
        let wrapped = model.process(engine.snapshot())
        XCTAssertTrue(wrapped.snapshot.lines.contains { $0.text == "abcdE" && $0.isSoftWrapped })

        engine.resize(columns: 8, rows: 3)
        let reflowed = model.process(engine.snapshot())
        XCTAssertTrue(reflowed.events.contains(.screenReplaced))
        XCTAssertEqual(completedTexts(in: reflowed.events), [])
        XCTAssertTrue(reflowed.snapshot.lines.contains { $0.text == "abcdE" })
    }

    func testScrollbackOrderingPreservesExistingCompletedLines() {
        let model = TerminalAccessibilityModel()
        _ = model.process(snapshot(
            revision: 0,
            scrollback: ["one"],
            viewport: ["two", ""],
            cursorRow: 1
        ))

        let update = model.process(snapshot(
            revision: 1,
            scrollback: ["one", "two"],
            viewport: ["three", ""],
            cursorRow: 1
        ))

        XCTAssertEqual(update.snapshot.lines.map(\.text), ["one", "two", "three", ""])
        XCTAssertEqual(completedTexts(in: update.events), ["three"])
    }

    func testOSC133MarksAreExposedWithoutInventingShellMeaning() {
        let engine = TerminalEngine(columns: 20, rows: 3)
        let model = TerminalAccessibilityModel()
        _ = model.process(engine.snapshot())

        engine.feed(Data(
            "\u{1B}]133;A\u{07}> \u{1B}]133;B\u{07}command\u{1B}]133;C\u{07} output".utf8
        ))
        let marked = engine.snapshot()
        let update = model.process(marked)

        XCTAssertFalse(marked.semanticPromptRows.isEmpty)
        XCTAssertFalse(marked.shellIntegrationMarks.isEmpty)
        XCTAssertTrue(update.events.contains(.shellIntegrationMarksAppeared(marked.shellIntegrationMarks)))
        XCTAssertTrue(update.snapshot.lines.contains { line in
            line.shellIntegrationMarks == marked.shellIntegrationMarks
        })
        let semanticContent = update.snapshot.currentLine?.shellSemanticContent ?? []
        XCTAssertTrue(semanticContent.contains(.prompt(.initial)))
        XCTAssertTrue(semanticContent.contains(.input))
        XCTAssertTrue(semanticContent.contains(.output))
        XCTAssertFalse(update.events.contains { event in
            if case .completedLinesAppended = event { return true }
            return false
        })
    }

    func testAlternateScreenRepaintsNeverBecomeShellHistoryAppends() {
        let engine = TerminalEngine(columns: 20, rows: 3)
        let model = TerminalAccessibilityModel()
        engine.feed(Data("shell output".utf8))
        _ = model.process(engine.snapshot())

        engine.feed(Data("\u{1B}[?1049hALT".utf8))
        let entered = model.process(engine.snapshot())
        engine.feed(Data(" repaint".utf8))
        let repainted = model.process(engine.snapshot())
        engine.feed(Data("\u{1B}[?1049l".utf8))
        let exited = model.process(engine.snapshot())

        XCTAssertTrue(entered.events.contains(.alternateScreenEntered))
        XCTAssertTrue(entered.events.contains(.screenReplaced))
        XCTAssertEqual(completedTexts(in: repainted.events), [])
        XCTAssertTrue(repainted.events.contains(.screenReplaced))
        XCTAssertTrue(exited.events.contains(.alternateScreenExited))
        XCTAssertTrue(exited.events.contains(.screenReplaced))
    }

    func testLargeNonAppendRepaintHasOneBoundedScreenReplacementEvent() {
        let model = TerminalAccessibilityModel()
        _ = model.process(snapshot(
            revision: 0,
            viewport: ["one", "two", ""],
            cursorRow: 2
        ))

        let repaint = model.process(snapshot(
            revision: 1,
            viewport: ["alpha", "beta", ""],
            cursorRow: 2
        ))

        XCTAssertEqual(repaint.events, [.screenReplaced])
    }

    private func completedTexts(in events: [TerminalAccessibilityEvent]) -> [String] {
        events.flatMap { event in
            guard case let .completedLinesAppended(lines) = event else { return [String]() }
            return lines.map(\.text)
        }
    }

    private func snapshot(
        revision: UInt64,
        scrollback: [String] = [],
        viewport: [String],
        cursorColumn: Int = 0,
        cursorRow: Int,
        dimensions: TerminalDimensions = TerminalDimensions(columns: 20, rows: 3),
        isAlternateScreen: Bool = false,
        semanticPromptRows: [Int] = []
    ) -> TerminalSnapshot {
        TerminalSnapshot(
            revision: revision,
            dimensions: dimensions,
            cursor: TerminalCursor(column: cursorColumn, row: cursorRow),
            viewport: viewport.map { TerminalLineSnapshot(text: $0, isWrappedContinuation: false) },
            scrollback: scrollback.map { TerminalLineSnapshot(text: $0, isWrappedContinuation: false) },
            isAlternateScreen: isAlternateScreen,
            semanticPromptRows: semanticPromptRows,
            shellIntegrationMarks: []
        )
    }
}
