import Foundation
import XCTest
@testable import FarRelay

@MainActor
final class TerminalEngineTests: XCTestCase {
    func testChunkingInvariantIncludesSplitUTF8AndANSI() {
        let bytes = Data("Aé\u{1B}[2D!\u{1B}[KZ".utf8)

        let whole = TerminalEngine(columns: 8, rows: 3)
        whole.feed(bytes)

        let bytewise = TerminalEngine(columns: 8, rows: 3)
        for byte in bytes {
            bytewise.feed(Data([byte]))
        }

        let chunked = TerminalEngine(columns: 8, rows: 3)
        chunked.feed(Data(bytes.prefix(2)))
        chunked.feed(Data(bytes.dropFirst(2).prefix(3)))
        chunked.feed(Data(bytes.dropFirst(5)))

        XCTAssertEqual(whole.snapshot().viewport, bytewise.snapshot().viewport)
        XCTAssertEqual(whole.snapshot().viewport, chunked.snapshot().viewport)
        XCTAssertEqual(whole.snapshot().viewport.first?.text, "!Z")
    }

    func testWrapResizeScrollbackAlternateScreenAndOSC133() {
        let engine = TerminalEngine(columns: 4, rows: 2, scrollback: 8)
        engine.feed(Data("abcdE\r\nline2\r\nline3".utf8))
        let beforeAlternate = engine.snapshot()
        XCTAssertTrue(beforeAlternate.scrollback.contains { $0.text.contains("abcd") })
        XCTAssertTrue(beforeAlternate.scrollback.contains { $0.isWrappedContinuation })

        engine.resize(columns: 6, rows: 3)
        XCTAssertEqual(engine.snapshot().dimensions, TerminalDimensions(columns: 6, rows: 3))
        engine.feed(Data("keep".utf8))

        engine.feed(Data("\u{1B}[?1049hALT\u{1B}[?1049l".utf8))
        let restored = engine.snapshot()
        XCTAssertFalse(restored.isAlternateScreen)
        XCTAssertTrue((restored.scrollback + restored.viewport).contains { $0.text.contains("keep") })

        engine.feed(Data("\u{1B}]133;A\u{07}>\u{1B}]133;B\u{07}command".utf8))
        XCTAssertFalse(engine.snapshot().semanticPromptRows.isEmpty)
    }
}
