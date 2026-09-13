import XCTest
@testable import FarRelay

final class ConversationAccessibilityActionTests: XCTestCase {
    func testCommandExposesCopyAndRunAgain() {
        let entry = AccessibleConversationEntry(text: "git status", role: .outboundCommand)
        XCTAssertEqual(
            ConversationAccessibilityActionPolicy.actions(for: entry),
            [.copy, .runAgain]
        )
        XCTAssertEqual(ConversationAccessibilityActionPolicy.copyText(for: entry), "git status")
    }

    func testIncomingOutputExposesCopyAndOpenSnapshot() {
        let entry = AccessibleConversationEntry(text: "On branch main", role: .incomingContent)
        XCTAssertEqual(
            ConversationAccessibilityActionPolicy.actions(for: entry),
            [.copy, .openSnapshot]
        )
        XCTAssertEqual(ConversationAccessibilityActionPolicy.copyText(for: entry), "On branch main")
    }

    func testCopyFromLargeOutputReturnsFullContent() {
        let text = (0..<TerminalConversationOutputLimits.largeOutputLineCount)
            .map { "line \($0)" }
            .joined(separator: "\n")
        let entry = AccessibleConversationEntry(text: text, role: .incomingContent)
        XCTAssertTrue(entry.isCompactLargeOutput)
        XCTAssertEqual(ConversationAccessibilityActionPolicy.copyText(for: entry), text)
        XCTAssertNotEqual(entry.presentationText, text)
    }

    func testSnapshotCopyAllUsesFrozenText() {
        let snapshot = AccessibleConversationSnapshot(
            sourceEntryID: UUID(),
            text: "frozen\noutput"
        )
        XCTAssertEqual(
            ConversationAccessibilityActionPolicy.copyAllText(for: snapshot),
            "frozen\noutput"
        )
        XCTAssertEqual(ConversationAccessibilityAction.copyAll.name, "Copy All")
    }

    func testClearInputIsOmittedWhenEmpty() {
        XCTAssertEqual(
            ConversationAccessibilityActionPolicy.inputActions(inputText: ""),
            [.sendCommand]
        )
        XCTAssertEqual(
            ConversationAccessibilityActionPolicy.inputActions(inputText: "ls"),
            [.sendCommand, .clearInput]
        )
    }
}
