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
            [Data(command.utf8), Data([0x0D])]
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
                Data(command.utf8), Data([0x0D]),
                Data(command.utf8), Data([0x0D])
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

    func testConfiguredControlKeysUseExpectedBytes() async {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: snapshot(revision: 1, viewport: ["", ""], cursorRow: 0)
        )
        let model = TerminalPresentationModel(session: session)
        let controls: [TerminalControlKey] = [
            TerminalControlKey(chord: .escape),
            TerminalControlKey(chord: .tab),
            TerminalControlKey(chord: .backspace),
            TerminalControlKey(chord: .upArrow),
            TerminalControlKey(chord: .downArrow),
            TerminalControlKey(chord: .rightArrow),
            TerminalControlKey(chord: .leftArrow),
            TerminalControlKey(chord: TerminalControlChord(baseKey: .letter, letter: "c", modifiers: [.control])),
            TerminalControlKey(chord: TerminalControlChord(baseKey: .letter, letter: "d", modifiers: [.control])),
        ]

        for control in controls {
            await model.send(control: control)
        }

        XCTAssertEqual(session.sentBytes, [
            Data([0x1B]), Data([0x09]), Data([0x7F]), Data("\u{1B}[A".utf8),
            Data("\u{1B}[B".utf8), Data("\u{1B}[C".utf8), Data("\u{1B}[D".utf8),
            Data([0x03]), Data([0x04]),
        ])
    }

    func testInvalidConfiguredControlIsNotSent() async {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: snapshot(revision: 1, viewport: ["", ""], cursorRow: 0)
        )
        let model = TerminalPresentationModel(session: session)
        let unsupported = TerminalControlKey(
            chord: TerminalControlChord(baseKey: .letter, letter: "p", modifiers: [.control, .shift])
        )

        await model.send(control: unsupported)

        XCTAssertTrue(session.sentBytes.isEmpty)
        XCTAssertEqual(
            model.lastInputError,
            TerminalControlChordError.ambiguousControlShift.explanation
        )
        XCTAssertEqual(model.lastInteractionFeedback?.kind, .error)
    }

    func testSuccessfulSendClearsInputAndFailedSendPreservesIt() async {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: snapshot(revision: 1, viewport: ["", ""], cursorRow: 0)
        )
        let model = TerminalPresentationModel(session: session)
        model.inputText = "git status"
        await model.submitInputText()
        XCTAssertEqual(model.inputText, "")
        XCTAssertEqual(model.lastInteractionFeedback?.kind, .selectionAccepted)

        session.sendError = TerminalSendFailure()
        model.inputText = "git push"
        await model.submitInputText()
        XCTAssertEqual(model.inputText, "git push")
        XCTAssertEqual(model.conversationEntries.map(\.text), ["git status"])
        XCTAssertEqual(model.lastInteractionFeedback?.kind, .error)
    }

    func testUnicodeInputIsByteExactUTF8WithoutExtraNewlines() async {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: snapshot(revision: 1, viewport: ["", ""], cursorRow: 0)
        )
        let model = TerminalPresentationModel(session: session)
        let command = "echo café 日本語 🌍"

        await model.submitInput(command)

        XCTAssertEqual(session.sentBytes, [Data(command.utf8), Data([0x0D])])
        XCTAssertEqual(model.conversationEntries.map(\.text), [command])
    }

    func testRepeatedCommandsCanBeSentSequentially() async {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: snapshot(revision: 1, viewport: ["", ""], cursorRow: 0)
        )
        let model = TerminalPresentationModel(session: session)
        await model.submitInput("pwd")
        await model.submitInput("ls")
        XCTAssertEqual(model.conversationEntries.map(\.text), ["pwd", "ls"])
        XCTAssertEqual(
            session.sentBytes,
            [Data("pwd".utf8), Data([0x0D]), Data("ls".utf8), Data([0x0D])]
        )
    }

    func testIncomingOutputDoesNotChangeInputText() {
        let model = TerminalPresentationModel()
        model.inputText = "still typing"
        model.setLiveOutputInputFocused(true)
        model.setLiveOutputVoiceOverEnabled(true)
        _ = model.process(snapshot(revision: 0, viewport: ["", ""], cursorRow: 0), sessionState: .connected)
        _ = model.process(
            snapshot(revision: 1, viewport: ["remote output", ""], cursorRow: 1),
            sessionState: .connected
        )
        XCTAssertEqual(model.inputText, "still typing")
        XCTAssertNil(model.liveOutputAnnouncement)
    }

    func testDisconnectedControlKeyRequestsErrorFeedback() async {
        let model = TerminalPresentationModel()
        await model.send(control: TerminalControlKey(chord: .escape))
        XCTAssertEqual(model.lastInputError, "Terminal is not connected.")
        XCTAssertEqual(model.lastInteractionFeedback?.kind, .error)
    }

    func testRunAgainFailureDoesNotDuplicateCommandAndRequestsError() async throws {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: snapshot(revision: 1, viewport: ["", ""], cursorRow: 0)
        )
        let model = TerminalPresentationModel(session: session)
        await model.submitInput("ls")
        let original = try XCTUnwrap(model.conversationEntries.first)
        session.sendError = TerminalSendFailure()
        await model.runAgain(commandID: original.id)
        XCTAssertEqual(model.conversationEntries.map(\.text), ["ls"])
        XCTAssertEqual(model.conversationEntries.map(\.id), [original.id])
        XCTAssertEqual(model.lastInteractionFeedback?.kind, .error)
    }

    func testCopyUsesCompleteLogicalTextAndOpenSnapshotKeepsFullContent() throws {
        let model = TerminalPresentationModel()
        var copied: [String] = []
        model.copyToClipboard = { copied.append($0) }
        _ = model.process(snapshot(
            revision: 1,
            viewport: ["first\nsecond", ""],
            cursorRow: 1
        ), sessionState: .connected)
        let entry = try XCTUnwrap(model.conversationEntries.first)

        XCTAssertEqual(
            model.accessibilityActions(for: entry),
            [.copy, .openSnapshot]
        )
        XCTAssertTrue(model.performCopy(for: entry.id))
        XCTAssertEqual(copied, ["first\nsecond"])
        XCTAssertEqual(model.lastInteractionFeedback?.kind, .copied)

        let snapshot = try XCTUnwrap(model.performOpenSnapshot(for: entry.id))
        XCTAssertEqual(snapshot.text, "first\nsecond")
        XCTAssertEqual(model.lastInteractionFeedback?.kind, .selectionAccepted)
    }

    func testCommandActionsExposeCopyAndRunAgain() async throws {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: snapshot(revision: 1, viewport: ["", ""], cursorRow: 0)
        )
        let model = TerminalPresentationModel(session: session)
        var copied: [String] = []
        model.copyToClipboard = { copied.append($0) }
        await model.submitInput("echo FarRelay")
        let command = try XCTUnwrap(model.conversationEntries.first)
        XCTAssertEqual(model.accessibilityActions(for: command), [.copy, .runAgain])
        XCTAssertTrue(model.performCopy(for: command.id))
        XCTAssertEqual(copied, ["echo FarRelay"])
        XCTAssertNil(model.captureSnapshot(for: command.id))
    }

    func testClearInputAndSendAccessibilityPolicy() {
        let model = TerminalPresentationModel()
        XCTAssertEqual(model.inputAccessibilityActions(), [.sendCommand])
        model.inputText = "pwd"
        XCTAssertEqual(model.inputAccessibilityActions(), [.sendCommand, .clearInput])
        model.clearInput()
        XCTAssertEqual(model.inputText, "")
        XCTAssertEqual(model.inputAccessibilityActions(), [.sendCommand])
    }

    func testConnectionStateChangesRequestSparseFeedback() {
        let model = TerminalPresentationModel()
        model.setSessionState(.connecting)
        XCTAssertNil(model.lastInteractionFeedback)
        model.setSessionState(.connected)
        XCTAssertEqual(model.lastInteractionFeedback?.kind, .success)
        model.setSessionState(.failed("no route"))
        XCTAssertEqual(model.lastInteractionFeedback?.kind, .error)
    }

    private func snapshot(
        revision: UInt64,
        viewport: [String],
        cursorRow: Int,
        isAlternateScreen: Bool = false
    ) -> TerminalSnapshot {
        TerminalPresentationFixtures.snapshot(
            revision: revision,
            viewport: viewport,
            cursorRow: cursorRow,
            isAlternateScreen: isAlternateScreen
        )
    }
}
