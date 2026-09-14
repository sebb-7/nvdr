import XCTest
@testable import FarRelay

@MainActor
final class AccessibleConversationAndDynamicReadingTests: XCTestCase {
    func testAccessibleTextFlattensNewlinesButRawTextStaysExact() {
        let raw = "The term hi is not\nrecognized as a program.\r\nTry again."
        let entry = AccessibleConversationEntry(text: raw, role: .incomingContent)

        XCTAssertEqual(entry.accessibilityText, "The term hi is not recognized as a program. Try again.")
        XCTAssertEqual(entry.text, raw)
        XCTAssertEqual(ConversationAccessibilityActionPolicy.copyText(for: entry), raw)
    }

    func testDynamicReadingKeepsInputFocusedOutputEligible() {
        let queue = DynamicReadingQueue()
        let sessionID = UUID()
        let entryID = UUID()
        let context = DynamicReadingContext(
            enabled: true,
            isVoiceOverEnabled: true,
            isReadingHistory: false,
            isSnapshotInspecting: false
        )

        queue.enqueue(
            entryID: entryID,
            sessionID: sessionID,
            text: "response",
            context: context
        )
        let announcements = queue.drain()

        XCTAssertEqual(announcements.map(\.text), ["response"])
    }

    func testDynamicReadingCoalescesOneStreamingEntryAndPreservesOrder() {
        let queue = DynamicReadingQueue()
        let context = DynamicReadingContext(enabled: true, isVoiceOverEnabled: true)
        let first = UUID()
        let second = UUID()
        let sessionID = UUID()

        queue.enqueue(entryID: first, sessionID: sessionID, text: "first partial", context: context)
        queue.enqueue(entryID: first, sessionID: sessionID, text: "first complete", context: context)
        queue.enqueue(entryID: second, sessionID: sessionID, text: "second", context: context)

        XCTAssertEqual(queue.drain().map(\.text), ["first complete", "second"])
    }

    func testDynamicReadingSuppressesStaleSession() {
        let queue = DynamicReadingQueue()
        let sessionID = UUID()
        let entryID = UUID()
        let context = DynamicReadingContext(enabled: true, isVoiceOverEnabled: true)
        queue.enqueue(entryID: entryID, sessionID: sessionID, text: "old", context: context)
        queue.cancel(sessionID: sessionID)

        XCTAssertEqual(
            queue.drain(),
            []
        )
    }

    func testVoiceOverActionPreferencesRoundTrip() throws {
        let preferences = VoiceOverActionPreferences(
            computerActions: [.editComputer],
            terminalActions: [.close],
            conversationCommandActions: [.runAgain],
            conversationOutputActions: [.openSnapshot]
        )
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(VoiceOverActionPreferences.self, from: data), preferences)
        XCTAssertEqual(
            HostProfileActionPolicy.actions(for: HostProfile(displayName: "G14"), preferences: preferences),
            [.newTerminal, .edit]
        )
    }

    func testDynamicReadingAndActionPreferencesPersistInAppSettings() {
        let suiteName = "AccessibleConversationAndDynamicReadingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.dynamicReadingEnabled = false
        settings.voiceOverActionPreferences.computerActions = [.editComputer]
        settings.save()

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.dynamicReadingEnabled)
        XCTAssertEqual(reloaded.voiceOverActionPreferences.computerActions, [.editComputer])
    }
}
