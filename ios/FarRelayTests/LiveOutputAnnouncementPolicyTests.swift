import XCTest
@testable import FarRelay

@MainActor
final class LiveOutputAnnouncementPolicyTests: XCTestCase {
    private let enabled = LiveOutputAnnouncementContext(isVoiceOverEnabled: true)

    func testCompletedContentAnnouncesInOrderAndSkipsBlankEntries() {
        let policy = LiveOutputAnnouncementPolicy()
        let effects = policy.completed([entry("first"), entry("   "), entry("second")], context: enabled)
        XCTAssertEqual(announcements(in: effects), ["first\nsecond"])
    }

    func testRepeatedCompletedEntryDoesNotDuplicate() {
        let policy = LiveOutputAnnouncementPolicy()
        let output = entry("complete")
        _ = policy.completed([output], context: enabled)
        XCTAssertTrue(policy.completed([output], context: enabled).isEmpty)
    }

    func testStreamingOnlyAnnouncesLatestSettledValue() {
        let policy = LiveOutputAnnouncementPolicy()
        let output = entry("b")
        let first = schedule(from: policy.streaming(output, context: enabled))
        var updated = output
        updated.text = "build complete"
        let second = schedule(from: policy.streaming(updated, context: enabled))

        XCTAssertTrue(policy.settle(token: first.token, context: enabled).isEmpty)
        XCTAssertEqual(announcements(in: policy.settle(token: second.token, context: enabled)), ["build complete"])
    }

    func testCompletionCancelsPendingStreamingWithoutDuplicate() {
        let policy = LiveOutputAnnouncementPolicy()
        let output = entry("build complete")
        let schedule = schedule(from: policy.streaming(output, context: enabled))
        XCTAssertEqual(announcements(in: policy.completed([output], context: enabled)), ["build complete"])
        XCTAssertTrue(policy.settle(token: schedule.token, context: enabled).isEmpty)
    }

    func testSuppressedOutputIsNotReplayed() {
        let policy = LiveOutputAnnouncementPolicy()
        let output = entry("later")
        var suppressed = enabled
        suppressed.isReadingHistory = true
        XCTAssertTrue(policy.completed([output], context: suppressed).isEmpty)
        suppressed.isReadingHistory = false
        XCTAssertTrue(policy.completed([output], context: enabled).isEmpty)
    }

    func testInputSnapshotAndVoiceOverGatingSuppressOutput() {
        let policy = LiveOutputAnnouncementPolicy()
        var context = enabled
        context.isInputFocused = true
        XCTAssertTrue(policy.completed([entry("input")], context: context).isEmpty)
        context.isInputFocused = false
        context.isSnapshotInspecting = true
        XCTAssertTrue(policy.completed([entry("snapshot")], context: context).isEmpty)
        XCTAssertTrue(policy.streaming(entry("off"), context: .init()).isEmpty)
    }

    func testResetCancelsPendingStreaming() {
        let policy = LiveOutputAnnouncementPolicy()
        let schedule = schedule(from: policy.streaming(entry("old terminal"), context: enabled))
        XCTAssertEqual(policy.reset(), [.cancelScheduled])
        XCTAssertTrue(policy.settle(token: schedule.token, context: enabled).isEmpty)
    }

    private func entry(_ text: String) -> AccessibleConversationEntry {
        AccessibleConversationEntry(text: text, role: .incomingContent)
    }

    private func schedule(from effects: [LiveOutputAnnouncementPolicyEffect]) -> LiveOutputAnnouncementSchedule {
        guard case let .schedule(schedule)? = effects.last else { fatalError("Expected a schedule") }
        return schedule
    }

    private func announcements(in effects: [LiveOutputAnnouncementPolicyEffect]) -> [String] {
        effects.compactMap { effect in
            guard case let .announce(announcement) = effect else { return nil }
            return announcement.text
        }
    }
}
