import Foundation
import XCTest
@testable import FarRelay

@MainActor
final class TerminalPresentationModelTests: XCTestCase {
    func testLiveModeBeginsAtCurrentTerminalContentInAccessibleOrder() {
        let model = TerminalPresentationModel()

        _ = model.process(snapshot(
            revision: 1,
            viewport: ["first", "current", ""],
            cursorRow: 1
        ), sessionState: .connected)

        XCTAssertEqual(model.mode, .live)
        XCTAssertEqual(model.activeLogicalLineIndex, 1)
        XCTAssertEqual(model.lines.map(\.text), ["first", "current", ""])
        XCTAssertEqual(model.accessibilityLabel(for: model.lines[1]), "Terminal line 2, current line, current")
    }

    func testReviewModePreservesSelectedLineWhenNewOutputArrives() {
        let model = TerminalPresentationModel()
        _ = model.process(snapshot(
            revision: 1,
            viewport: ["earlier", "current", ""],
            cursorRow: 1
        ), sessionState: .connected)

        model.enterReview(at: 0)
        _ = model.process(snapshot(
            revision: 2,
            viewport: ["earlier", "new output", "current"],
            cursorRow: 2
        ), sessionState: .connected)

        XCTAssertEqual(model.mode, .review)
        XCTAssertEqual(model.activeLogicalLineIndex, 0)
        XCTAssertEqual(model.reviewedLogicalLineIndex, 0)
        XCTAssertEqual(model.lines.map(\.text), ["earlier", "new output", "current"])
    }

    func testReturnToLiveMovesToCurrentTerminalLine() {
        let model = TerminalPresentationModel()
        _ = model.process(snapshot(
            revision: 1,
            viewport: ["older", "live", ""],
            cursorRow: 1
        ), sessionState: .connected)
        model.enterReview(at: 0)

        model.returnToLive()

        XCTAssertEqual(model.mode, .live)
        XCTAssertEqual(model.activeLogicalLineIndex, 1)
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

    func testTextSubmissionPreservesUnicodeAndAppendsReturn() async {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: snapshot(revision: 1, viewport: ["", ""], cursorRow: 0)
        )
        let model = TerminalPresentationModel(session: session)

        await model.submitInput("echo 🌍")

        XCTAssertEqual(
            session.sentBytes,
            [Data("echo 🌍".utf8), TerminalPresentationAction.returnKey.inputBytes]
        )
        XCTAssertNil(model.lastInputError)
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

    func testAlternateScreenRemainsCoherentPresentationContent() {
        let model = TerminalPresentationModel()
        _ = model.process(snapshot(
            revision: 1,
            viewport: ["shell history", ""],
            cursorRow: 1
        ), sessionState: .connected)

        let alternate = model.process(snapshot(
            revision: 2,
            viewport: ["vim buffer", ""],
            cursorRow: 0,
            isAlternateScreen: true
        ), sessionState: .connected)

        XCTAssertTrue(alternate.events.contains(.alternateScreenEntered))
        XCTAssertTrue(alternate.events.contains(.screenReplaced))
        XCTAssertTrue(model.accessibleSnapshot?.isAlternateScreen == true)
        XCTAssertEqual(model.lines.map(\.text), ["vim buffer", ""])
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

    init(state: TerminalPresentationSessionState, snapshot: TerminalSnapshot) {
        terminalPresentationState = state
        terminalPresentationSnapshot = snapshot
    }

    func sendTerminalInput(_ bytes: Data) async throws {
        sentBytes.append(bytes)
    }

    func resizeTerminal(columns: Int, rows: Int) async throws {}
}
