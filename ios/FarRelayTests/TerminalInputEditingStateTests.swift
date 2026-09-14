import XCTest
@testable import FarRelay

final class TerminalInputEditingStateTests: XCTestCase {
    func testBrowseActivateAndLeaveTransitionsAreExplicit() {
        var state: TerminalInputEditingState = .browsing

        state.activateInput()
        XCTAssertEqual(state, .editing)

        state.leaveTerminal()
        XCTAssertEqual(state, .browsing)
    }

    func testRepeatedSuccessfulAndFailedSubmissionsKeepEditorOwnedByInput() {
        var state: TerminalInputEditingState = .browsing
        state.activateInput()

        // A successful submission, failed send, incoming output, and Dynamic
        // Reading do not mutate the local editor's ownership state.
        state.submissionCompleted()
        XCTAssertEqual(state, .editing)
        state.submissionCompleted()
        XCTAssertEqual(state, .editing)
    }

    func testUIKitResponderCallbacksConfirmTheSameEditingState() {
        var state: TerminalInputEditingState = .browsing
        state.didBeginEditing()
        XCTAssertTrue(state.isEditing)
        state.didEndEditing()
        XCTAssertFalse(state.isEditing)
    }
}
