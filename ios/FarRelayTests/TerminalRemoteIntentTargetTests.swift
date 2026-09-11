import Foundation
import XCTest
@testable import FarRelay

@MainActor
final class TerminalRemoteIntentTargetTests: XCTestCase {
    func testReviewIntentsReusePresentationNavigation() async {
        let session = FakeTerminalIntentSession()
        let model = connectedModel(session: session)
        let target = TerminalRemoteIntentTarget(presentation: model)
        model.enterReview(at: 1)

        let previous = await target.perform(.reviewPrevious)
        XCTAssertEqual(previous, .performed)
        XCTAssertEqual(model.reviewedLogicalLineIndex, 0)

        let next = await target.perform(.reviewNext)
        XCTAssertEqual(next, .performed)
        XCTAssertEqual(model.reviewedLogicalLineIndex, 1)

        let live = await target.perform(.returnToLive)
        XCTAssertEqual(live, .performed)
        XCTAssertEqual(model.mode, .live)
    }

    func testControlAndGenericTerminalIntentsReusePresentationActions() async {
        let session = FakeTerminalIntentSession()
        let target = TerminalRemoteIntentTarget(presentation: connectedModel(session: session))

        let interrupt = await target.perform(.terminalInterrupt)
        let eof = await target.perform(.terminalEOF)
        let activate = await target.perform(.activate)
        let cancel = await target.perform(.cancel)

        XCTAssertEqual([interrupt, eof, activate, cancel], [.performed, .performed, .performed, .performed])
        XCTAssertEqual(
            session.sentBytes,
            [
                TerminalPresentationAction.interrupt.inputBytes,
                TerminalPresentationAction.endOfTransmission.inputBytes,
                TerminalPresentationAction.returnKey.inputBytes,
                TerminalPresentationAction.escape.inputBytes
            ]
        )
    }

    func testRawTerminalKeyUsesOnlyClearTerminalEquivalent() async {
        let session = FakeTerminalIntentSession()
        let target = TerminalRemoteIntentTarget(presentation: connectedModel(session: session))

        let tab = await target.perform(.sendKey(.tab))
        let unsupported = await target.perform(.sendChord(RemoteChord(modifiers: [.alt], key: .tab)))

        XCTAssertEqual(tab, .performed)
        XCTAssertEqual(unsupported, .unsupported)
        XCTAssertEqual(session.sentBytes, [TerminalPresentationAction.tab.inputBytes])
    }

    func testApplicationIntentIsUnsupportedByTerminalTarget() async {
        let target = TerminalRemoteIntentTarget(presentation: connectedModel(session: FakeTerminalIntentSession()))

        let result = await target.perform(.nextApplication)

        XCTAssertEqual(result, .unsupported)
    }

    func testDisconnectedTerminalIsUnavailable() async {
        let target = TerminalRemoteIntentTarget(presentation: TerminalPresentationModel())

        let result = await target.perform(.terminalInterrupt)

        XCTAssertEqual(result, .unavailable("The SSH terminal is not connected."))
    }

    private func connectedModel(session: FakeTerminalIntentSession) -> TerminalPresentationModel {
        let model = TerminalPresentationModel(session: session)
        _ = model.process(
            TerminalSnapshot(
                revision: 1,
                dimensions: TerminalDimensions(columns: 20, rows: 3),
                cursor: TerminalCursor(column: 0, row: 2),
                viewport: ["first", "second", "current"].map {
                    TerminalLineSnapshot(text: $0, isWrappedContinuation: false)
                },
                scrollback: [],
                isAlternateScreen: false,
                semanticPromptRows: [],
                shellIntegrationMarks: []
            ),
            sessionState: .connected
        )
        return model
    }
}

@MainActor
private final class FakeTerminalIntentSession: TerminalPresentationSession {
    let terminalPresentationSnapshot = TerminalSnapshot(
        revision: 0,
        dimensions: TerminalDimensions(columns: 20, rows: 1),
        cursor: TerminalCursor(column: 0, row: 0),
        viewport: [TerminalLineSnapshot(text: "", isWrappedContinuation: false)],
        scrollback: [],
        isAlternateScreen: false,
        semanticPromptRows: [],
        shellIntegrationMarks: []
    )
    let terminalPresentationState: TerminalPresentationSessionState = .connected
    private(set) var sentBytes: [Data] = []

    func sendTerminalInput(_ bytes: Data) async throws {
        sentBytes.append(bytes)
    }

    func resizeTerminal(columns: Int, rows: Int) async throws {}
}
