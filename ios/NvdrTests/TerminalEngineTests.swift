import Foundation
import XCTest
@testable import Nvdr

@MainActor
final class TerminalEngineTests: XCTestCase {
    func testPlainTextAndScrollbackProduceInspectableSnapshots() throws {
        let engine = try TerminalEngine(
            dimensions: TerminalDimensions(columns: 8, rows: 2),
            scrollbackLimit: 10
        )

        let snapshot = engine.ingest(Data("one\r\ntwo\r\nthree".utf8))

        XCTAssertEqual(snapshot.viewport.map(\.text), ["two", "three"])
        XCTAssertEqual(snapshot.scrollback.map(\.text), ["one"])
        XCTAssertEqual(snapshot.cursor, TerminalCursor(column: 5, row: 1))
        XCTAssertEqual(snapshot.revision, 1)
    }

    func testAnsiCursorMovementAndEraseUpdateTheScreenModel() throws {
        let engine = try TerminalEngine(dimensions: TerminalDimensions(columns: 8, rows: 2))

        let snapshot = engine.ingest(Data("abc\u{1B}[2D\u{1B}[KZ".utf8))

        XCTAssertEqual(snapshot.viewport.first?.text, "aZ")
        XCTAssertEqual(snapshot.cursor, TerminalCursor(column: 2, row: 0))
    }

    func testWrappingAndSplitUTF8InputPreserveTerminalState() throws {
        let engine = try TerminalEngine(dimensions: TerminalDimensions(columns: 4, rows: 2))

        _ = engine.ingest(Data("abcd".utf8))
        _ = engine.ingest(Data([0xC3]))
        let completedSnapshot = engine.ingest(Data([0xA9]))

        XCTAssertTrue(completedSnapshot.viewport[0].isWrapped)
        XCTAssertEqual(completedSnapshot.viewport.map(\.text), ["abcd", "é"])
        XCTAssertEqual(completedSnapshot.cursor, TerminalCursor(column: 1, row: 1))
    }

    func testAlternateScreenDoesNotOverwriteRetainedNormalScrollback() throws {
        let engine = try TerminalEngine(
            dimensions: TerminalDimensions(columns: 8, rows: 2),
            scrollbackLimit: 10
        )
        _ = engine.ingest(Data("one\r\ntwo\r\nthree".utf8))

        let alternate = engine.ingest(Data("\u{1B}[?1049halt".utf8))

        XCTAssertTrue(alternate.isAlternateScreen)
        XCTAssertEqual(alternate.viewport.first?.text, "alt")
        XCTAssertTrue(alternate.scrollback.isEmpty)

        let restored = engine.ingest(Data("\u{1B}[?1049l".utf8))
        XCTAssertFalse(restored.isAlternateScreen)
        XCTAssertEqual(restored.viewport.map(\.text), ["two", "three"])
        XCTAssertEqual(restored.scrollback.map(\.text), ["one"])
    }

    func testResizeChangesTheParserGridWithoutAView() throws {
        let engine = try TerminalEngine(dimensions: TerminalDimensions(columns: 8, rows: 2))

        let snapshot = try engine.resize(columns: 4, rows: 3)

        XCTAssertEqual(snapshot.dimensions, try TerminalDimensions(columns: 4, rows: 3))
        XCTAssertEqual(snapshot.viewport.count, 3)
        XCTAssertEqual(snapshot.revision, 1)
    }
}
