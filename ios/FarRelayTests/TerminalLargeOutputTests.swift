import XCTest
@testable import FarRelay

@MainActor
final class TerminalLargeOutputTests: XCTestCase {
    func testBelowThresholdRemainsOrdinaryResponse() {
        let model = connectedModel()
        let lines = numberedLines(TerminalConversationOutputLimits.largeOutputLineCount - 1)
        _ = model.process(outputSnapshot(revision: 1, lines: lines), sessionState: .connected)
        let entry = model.conversationEntries[0]
        XCTAssertFalse(entry.isCompactLargeOutput)
        XCTAssertEqual(entry.presentationText, lines.joined(separator: "\n"))
        XCTAssertEqual(entry.logicalLineCount, 49)
    }

    func testThresholdBoundaryBecomesCompactLargeOutput() {
        let model = connectedModel()
        let lines = numberedLines(TerminalConversationOutputLimits.largeOutputLineCount)
        _ = model.process(outputSnapshot(revision: 1, lines: lines), sessionState: .connected)
        let entry = model.conversationEntries[0]
        XCTAssertTrue(entry.isCompactLargeOutput)
        XCTAssertEqual(entry.logicalLineCount, 50)
        XCTAssertEqual(entry.presentationText, "Large output, 50 lines. Open Snapshot.")
        XCTAssertEqual(entry.text, lines.joined(separator: "\n"))
    }

    func testAboveThresholdStaysCompactAndPreservesFullSnapshot() throws {
        let model = connectedModel()
        model.setLiveOutputVoiceOverEnabled(true)
        let lines = numberedLines(TerminalConversationOutputLimits.largeOutputLineCount + 1)
        _ = model.process(outputSnapshot(revision: 1, lines: lines), sessionState: .connected)
        let entry = try XCTUnwrap(model.conversationEntries.first)
        XCTAssertTrue(entry.isCompactLargeOutput)
        XCTAssertEqual(entry.presentationText, "Large output, 51 lines. Open Snapshot.")

        let snapshot = try XCTUnwrap(model.captureSnapshot(for: entry.id))
        XCTAssertEqual(snapshot.text, lines.joined(separator: "\n"))
        XCTAssertEqual(snapshot.sourceEntryID, entry.id)
        XCTAssertEqual(model.liveOutputAnnouncement?.text, "Large output received, 51 lines.")
    }

    func testCharacterThresholdAlsoCompacts() {
        let model = connectedModel()
        let text = String(repeating: "a", count: TerminalConversationOutputLimits.largeOutputCharacterCount)
        _ = model.process(outputSnapshot(revision: 1, lines: [text]), sessionState: .connected)
        let entry = model.conversationEntries[0]
        XCTAssertTrue(entry.isCompactLargeOutput)
        XCTAssertEqual(entry.text, text)
        XCTAssertEqual(entry.text.count, 4_000)
    }

    func testJustBelowCharacterThresholdRemainsOrdinary() {
        let model = connectedModel()
        let text = String(repeating: "a", count: TerminalConversationOutputLimits.largeOutputCharacterCount - 1)
        _ = model.process(outputSnapshot(revision: 1, lines: [text]), sessionState: .connected)
        XCTAssertFalse(model.conversationEntries[0].isCompactLargeOutput)
        XCTAssertEqual(model.conversationEntries[0].presentationText, text)
    }

    func testCopyFromLargeOutputReturnsFullContent() {
        let model = connectedModel()
        var copied: [String] = []
        model.copyToClipboard = { copied.append($0) }
        let lines = numberedLines(60)
        _ = model.process(outputSnapshot(revision: 1, lines: lines), sessionState: .connected)
        let entry = model.conversationEntries[0]
        XCTAssertTrue(model.performCopy(for: entry.id))
        XCTAssertEqual(copied, [lines.joined(separator: "\n")])
    }

    func testLargeOutputDoesNotAlterInputOrFocusPolicy() {
        let model = connectedModel()
        model.inputText = "next command"
        model.setLiveOutputInputFocused(true)
        model.setLiveOutputVoiceOverEnabled(true)
        _ = model.process(
            outputSnapshot(revision: 1, lines: numberedLines(60)),
            sessionState: .connected
        )
        XCTAssertEqual(model.inputText, "next command")
        XCTAssertNil(model.liveOutputAnnouncement)
    }

    func testLargeOutputDoesNotBecomeConversationOnAlternateScreen() {
        let model = connectedModel()
        let lines = numberedLines(60)
        _ = model.process(
            TerminalPresentationFixtures.output(
                revision: 1,
                lines: lines,
                isAlternateScreen: true
            ),
            sessionState: .connected
        )
        XCTAssertTrue(model.conversationEntries.isEmpty)
        XCTAssertEqual(model.alternateScreenLines.count, 60)
    }

    private func connectedModel() -> TerminalPresentationModel {
        let model = TerminalPresentationModel()
        _ = model.process(
            TerminalPresentationFixtures.empty(revision: 0),
            sessionState: .connected
        )
        return model
    }

    private func numberedLines(_ count: Int) -> [String] {
        (0..<count).map { "line \($0)" }
    }

    private func outputSnapshot(revision: UInt64, lines: [String]) -> TerminalSnapshot {
        TerminalPresentationFixtures.output(revision: revision, lines: lines)
    }
}
