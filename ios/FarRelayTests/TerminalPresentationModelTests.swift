import Foundation
import XCTest
@testable import FarRelay

@MainActor
final class TerminalPresentationModelTests: XCTestCase {
    func testBlankViewportRowsAreNotConversationClutterAndUsefulOutputRemains() {
        let model = TerminalPresentationModel()

        _ = model.process(snapshot(
            revision: 1,
            viewport: ["useful output", "", "   ", ""],
            cursorRow: 3
        ), sessionState: .connected)

        XCTAssertEqual(model.conversationEntries.map(\.text), ["useful output"])
        XCTAssertEqual(model.conversationEntries.map(\.role), [.incomingContent])
    }

    func testInitialHistoryDoesNotCreateLiveAnnouncementButNewCompletedOutputDoes() {
        let model = TerminalPresentationModel()
        model.setLiveOutputVoiceOverEnabled(true)
        _ = model.process(snapshot(
            revision: 1,
            viewport: ["history", "", ""],
            cursorRow: 2
        ), sessionState: .connected)
        XCTAssertNil(model.liveOutputAnnouncement)

        _ = model.process(snapshot(
            revision: 2,
            viewport: ["history", "new output", ""],
            cursorRow: 2
        ), sessionState: .connected)
        XCTAssertEqual(model.liveOutputAnnouncement?.text, "new output")
    }

    func testResizeAndAlternateScreenDoNotCreateLiveOutputAnnouncements() {
        let model = TerminalPresentationModel()
        model.setLiveOutputVoiceOverEnabled(true)
        _ = model.process(snapshot(revision: 1, viewport: ["one", "", ""], cursorRow: 2), sessionState: .connected)

        _ = model.process(snapshot(revision: 2, viewport: ["one", "", "", ""], cursorRow: 3), sessionState: .connected)
        XCTAssertNil(model.liveOutputAnnouncement)
        _ = model.process(snapshot(
            revision: 3,
            viewport: ["vim repaint", "", "", ""],
            cursorRow: 0,
            isAlternateScreen: true
        ), sessionState: .connected)
        XCTAssertNil(model.liveOutputAnnouncement)
    }

    func testSoftWrappedOutputRemainsOneLogicalConversationEntry() {
        let model = TerminalPresentationModel()
        let terminalSnapshot = TerminalSnapshot(
            revision: 1,
            dimensions: TerminalDimensions(columns: 4, rows: 3),
            cursor: TerminalCursor(column: 1, row: 1),
            viewport: [
                TerminalLineSnapshot(text: "abcd", isWrappedContinuation: false),
                TerminalLineSnapshot(text: "E", isWrappedContinuation: true),
                TerminalLineSnapshot(text: "", isWrappedContinuation: false)
            ],
            scrollback: [],
            isAlternateScreen: false,
            semanticPromptRows: [],
            shellIntegrationMarks: []
        )

        _ = model.process(terminalSnapshot, sessionState: .connected)

        XCTAssertEqual(model.conversationEntries.map(\.text), ["abcdE"])
    }

    func testSubmittedCommandIsExactDistinctAndContentFirst() async {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: snapshot(revision: 1, viewport: ["", ""], cursorRow: 0)
        )
        let model = TerminalPresentationModel(session: session)
        let command = "echo 🌍  "

        await model.submitInput(command)

        XCTAssertEqual(
            session.sentBytes,
            [Data(command.utf8), TerminalPresentationAction.returnKey.inputBytes]
        )
        XCTAssertEqual(model.conversationEntries.map(\.text), [command])
        XCTAssertEqual(model.conversationEntries.map(\.role), [.outboundCommand])
        XCTAssertTrue(model.conversationEntries[0].isCommand)
        XCTAssertEqual(model.accessibilityLabel(for: model.conversationEntries[0]), command)
        XCTAssertFalse(model.accessibilityLabel(for: model.conversationEntries[0]).contains("Terminal line"))
    }

    func testRunAgainResendsExactCommandAndCreatesNewOutboundInteraction() async throws {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: snapshot(revision: 1, viewport: ["", ""], cursorRow: 0)
        )
        let model = TerminalPresentationModel(session: session)
        let command = "printf '%s\\n' 'FarRelay'"

        await model.submitInput(command)
        let original = try XCTUnwrap(model.conversationEntries.first)
        await model.runAgain(commandID: original.id)

        XCTAssertEqual(
            session.sentBytes,
            [
                Data(command.utf8), TerminalPresentationAction.returnKey.inputBytes,
                Data(command.utf8), TerminalPresentationAction.returnKey.inputBytes
            ]
        )
        XCTAssertEqual(model.conversationEntries.map(\.text), [command, command])
        XCTAssertNotEqual(model.conversationEntries[0].id, model.conversationEntries[1].id)
        XCTAssertEqual(model.conversationEntries.map(\.role), [.outboundCommand, .outboundCommand])
    }

    func testNewTerminalLifetimeDoesNotLeakOldConversationHistory() {
        let model = TerminalPresentationModel()
        _ = model.process(snapshot(
            revision: 1,
            viewport: ["old shell output", ""],
            cursorRow: 1
        ), sessionState: .connected)

        model.beginConnecting()
        _ = model.process(snapshot(
            revision: 1,
            viewport: ["new shell output", ""],
            cursorRow: 1
        ), sessionState: .connected)

        XCTAssertEqual(model.conversationEntries.map(\.text), ["new shell output"])
    }

    func testStreamingCurrentLineUpdatesOneEntryInsteadOfAppendingNoise() {
        let model = TerminalPresentationModel()
        _ = model.process(snapshot(revision: 0, viewport: ["", ""], cursorRow: 0), sessionState: .connected)

        _ = model.process(snapshot(
            revision: 1,
            viewport: ["hel", ""],
            cursorRow: 0
        ), sessionState: .connected)
        _ = model.process(snapshot(
            revision: 2,
            viewport: ["hello", ""],
            cursorRow: 0
        ), sessionState: .connected)
        _ = model.process(snapshot(
            revision: 3,
            viewport: ["hello", ""],
            cursorRow: 1
        ), sessionState: .connected)

        XCTAssertEqual(model.conversationEntries.map(\.text), ["hello"])
        XCTAssertEqual(model.conversationEntries.map(\.role), [.incomingContent])
    }

    func testSnapshotCapturesIncomingConversationTextExactlyAndKeepsItsIdentity() throws {
        let model = TerminalPresentationModel()
        let text = "first line\nsecond line\n🌍"
        _ = model.process(snapshot(
            revision: 1,
            viewport: [text, ""],
            cursorRow: 1
        ), sessionState: .connected)
        let entry = try XCTUnwrap(model.conversationEntries.first)
        let outputSnapshot = try XCTUnwrap(model.captureSnapshot(for: entry.id))

        XCTAssertEqual(outputSnapshot.sourceEntryID, entry.id)
        XCTAssertEqual(outputSnapshot.text, text)
        XCTAssertEqual(model.conversationEntries, [entry])
    }

    func testStreamingMutationDoesNotChangeCapturedSnapshot() throws {
        let model = TerminalPresentationModel()
        _ = model.process(snapshot(revision: 0, viewport: ["", ""], cursorRow: 0), sessionState: .connected)
        _ = model.process(snapshot(
            revision: 1,
            viewport: ["building", ""],
            cursorRow: 0
        ), sessionState: .connected)
        let entry = try XCTUnwrap(model.conversationEntries.first)
        let outputSnapshot = try XCTUnwrap(model.captureSnapshot(for: entry.id))
        let snapshotID = outputSnapshot.id

        _ = model.process(snapshot(
            revision: 2,
            viewport: ["building complete", ""],
            cursorRow: 0
        ), sessionState: .connected)

        XCTAssertEqual(outputSnapshot.text, "building")
        XCTAssertEqual(outputSnapshot.id, snapshotID)
        XCTAssertEqual(model.conversationEntries.map(\.text), ["building complete"])
        XCTAssertEqual(model.conversationEntries.first?.id, entry.id)
    }

    func testNewOutputAndTerminalResetDoNotChangeCapturedSnapshot() throws {
        let model = TerminalPresentationModel()
        _ = model.process(snapshot(
            revision: 1,
            viewport: ["captured output", "", ""],
            cursorRow: 2
        ), sessionState: .connected)
        let entry = try XCTUnwrap(model.conversationEntries.first)
        let outputSnapshot = try XCTUnwrap(model.captureSnapshot(for: entry.id))

        _ = model.process(snapshot(
            revision: 2,
            viewport: ["captured output", "later output", ""],
            cursorRow: 2
        ), sessionState: .connected)
        XCTAssertEqual(model.conversationEntries.map(\.text), ["captured output", "later output"])

        model.beginConnecting()
        _ = model.process(snapshot(
            revision: 1,
            viewport: ["new terminal output", ""],
            cursorRow: 1
        ), sessionState: .connected)

        XCTAssertEqual(outputSnapshot.text, "captured output")
        XCTAssertEqual(outputSnapshot.sourceEntryID, entry.id)
        XCTAssertEqual(model.conversationEntries.map(\.text), ["new terminal output"])
    }

    func testSnapshotsOnlyCaptureIncomingContent() async throws {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: snapshot(revision: 1, viewport: ["", ""], cursorRow: 0)
        )
        let model = TerminalPresentationModel(session: session)
        await model.submitInput("echo FarRelay")
        let command = try XCTUnwrap(model.conversationEntries.first)

        XCTAssertNil(model.captureSnapshot(for: command.id))
        XCTAssertEqual(model.conversationEntries, [command])
    }

    func testAlternateScreenUsesSafeReplacementContentWithoutAppendingHistory() {
        let model = TerminalPresentationModel()
        _ = model.process(snapshot(
            revision: 1,
            viewport: ["shell history", ""],
            cursorRow: 1
        ), sessionState: .connected)

        let entered = model.process(snapshot(
            revision: 2,
            viewport: ["vim buffer", ""],
            cursorRow: 0,
            isAlternateScreen: true
        ), sessionState: .connected)

        XCTAssertTrue(entered.events.contains(.alternateScreenEntered))
        XCTAssertEqual(model.conversationEntries.map(\.text), ["shell history"])
        XCTAssertEqual(model.alternateScreenLines.map(\.text), ["vim buffer"])
    }

    func testAttachConsumesPublishedTerminalUpdatesWithoutPolling() {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: snapshot(revision: 1, viewport: ["initial", "", ""], cursorRow: 2)
        )
        let model = TerminalPresentationModel()

        model.attach(session)
        session.publish(snapshot(
            revision: 2,
            viewport: ["initial", "updated", ""],
            cursorRow: 2
        ), state: .connected)

        XCTAssertEqual(model.conversationEntries.map(\.text), ["initial", "updated"])
    }

    func testSessionFailureAndEndExposeUsefulPresentationStates() {
        let failedSession = FakeTerminalPresentationSession(
            state: .failed("Remote host closed the terminal."),
            snapshot: snapshot(revision: 1, viewport: ["", ""], cursorRow: 0)
        )
        let failedModel = TerminalPresentationModel(session: failedSession)

        failedModel.refresh()
        XCTAssertEqual(failedModel.sessionState, .failed("Remote host closed the terminal."))
        XCTAssertEqual(
            failedModel.sessionState.accessibilityLabel,
            "Terminal failed: Remote host closed the terminal."
        )

        let endedSession = FakeTerminalPresentationSession(
            state: .ended,
            snapshot: snapshot(revision: 1, viewport: ["done", ""], cursorRow: 1)
        )
        let endedModel = TerminalPresentationModel(session: endedSession)

        endedModel.refresh()
        XCTAssertEqual(endedModel.sessionState, .ended)
        XCTAssertEqual(endedModel.sessionState.accessibilityLabel, "Terminal session ended.")
    }

    func testEssentialTerminalActionsUseExpectedBytes() async {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: snapshot(revision: 1, viewport: ["", ""], cursorRow: 0)
        )
        let model = TerminalPresentationModel(session: session)
        let actions: [TerminalPresentationAction] = [
            .escape, .tab, .backspace, .upArrow, .downArrow,
            .rightArrow, .leftArrow, .interrupt, .endOfTransmission
        ]

        for action in actions {
            await model.send(action)
        }

        XCTAssertEqual(session.sentBytes, actions.map(\.inputBytes))
    }

    private func snapshot(
        revision: UInt64,
        viewport: [String],
        cursorRow: Int,
        isAlternateScreen: Bool = false
    ) -> TerminalSnapshot {
        TerminalSnapshot(
            revision: revision,
            dimensions: TerminalDimensions(columns: 20, rows: viewport.count),
            cursor: TerminalCursor(column: 0, row: cursorRow),
            viewport: viewport.map { TerminalLineSnapshot(text: $0, isWrappedContinuation: false) },
            scrollback: [],
            isAlternateScreen: isAlternateScreen,
            semanticPromptRows: [],
            shellIntegrationMarks: []
        )
    }
}

@MainActor
private final class FakeTerminalPresentationSession: TerminalPresentationSession {
    var terminalPresentationSnapshot: TerminalSnapshot
    var terminalPresentationState: TerminalPresentationSessionState
    private(set) var sentBytes: [Data] = []
    private var observer: (@MainActor (TerminalSnapshot, TerminalPresentationSessionState) -> Void)?

    init(state: TerminalPresentationSessionState, snapshot: TerminalSnapshot) {
        terminalPresentationState = state
        terminalPresentationSnapshot = snapshot
    }

    func observeTerminalPresentationUpdates(
        _ observer: @escaping @MainActor (TerminalSnapshot, TerminalPresentationSessionState) -> Void
    ) {
        self.observer = observer
    }

    func sendTerminalInput(_ bytes: Data) async throws {
        sentBytes.append(bytes)
    }

    func resizeTerminal(columns: Int, rows: Int) async throws {}

    func publish(_ snapshot: TerminalSnapshot, state: TerminalPresentationSessionState) {
        terminalPresentationSnapshot = snapshot
        terminalPresentationState = state
        observer?(snapshot, state)
    }
}
