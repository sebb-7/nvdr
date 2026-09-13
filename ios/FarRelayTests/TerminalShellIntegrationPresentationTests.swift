import XCTest
@testable import FarRelay

@MainActor
final class TerminalShellIntegrationPresentationTests: XCTestCase {
    func testOSC133GroupedOutputFormsOneLogicalResponseBlock() async {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: TerminalPresentationFixtures.empty(revision: 0)
        )
        let model = TerminalPresentationModel(session: session)
        await model.submitInput("git status")

        _ = model.process(
            TerminalPresentationFixtures.output(
                revision: 1,
                lines: ["On branch main", "Your branch is up to date.", "nothing to commit"]
            ),
            sessionState: .connected
        )

        XCTAssertEqual(model.conversationEntries.map(\.role), [.outboundCommand, .incomingContent])
        XCTAssertEqual(
            model.conversationEntries.map(\.text),
            ["git status", "On branch main\nYour branch is up to date.\nnothing to commit"]
        )
    }

    func testCommandEchoIsSuppressedOnlyWhenSemanticallyProven() async {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: TerminalPresentationFixtures.empty(revision: 0)
        )
        let model = TerminalPresentationModel(session: session)
        await model.submitInput("git status")

        _ = model.process(
            TerminalPresentationFixtures.snapshot(
                revision: 1,
                viewport: ["git status", ""],
                cursorRow: 1,
                semantics: [[.input], []],
                rows: TerminalPresentationFixtures.defaultRows
            ),
            sessionState: .connected
        )

        XCTAssertEqual(model.conversationEntries.map(\.text), ["git status"])
        XCTAssertEqual(model.conversationEntries.map(\.role), [.outboundCommand])
    }

    func testIdenticalUnmarkedProgramOutputIsNotSuppressed() async {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: TerminalPresentationFixtures.empty(revision: 0)
        )
        let model = TerminalPresentationModel(session: session)
        await model.submitInput("git status")

        _ = model.process(
            TerminalPresentationFixtures.snapshot(
                revision: 1,
                viewport: ["git status", ""],
                cursorRow: 1,
                rows: TerminalPresentationFixtures.defaultRows
            ),
            sessionState: .connected
        )

        XCTAssertEqual(model.conversationEntries.map(\.text), ["git status", "git status"])
        XCTAssertEqual(model.conversationEntries.map(\.role), [.outboundCommand, .incomingContent])
    }

    func testPromptMarksDoNotCreateNoisyResponseEntries() async {
        let session = FakeTerminalPresentationSession(
            state: .connected,
            snapshot: TerminalPresentationFixtures.empty(revision: 0)
        )
        let model = TerminalPresentationModel(session: session)
        await model.submitInput("pwd")

        _ = model.process(
            TerminalPresentationFixtures.snapshot(
                revision: 1,
                viewport: ["/home/reader", "reader@host:~$", ""],
                cursorRow: 2,
                semantics: [[.output], [.prompt(.initial)], []],
                marks: [TerminalShellIntegrationMark(row: 1, column: 0, kind: .initial)],
                rows: TerminalPresentationFixtures.defaultRows
            ),
            sessionState: .connected
        )

        XCTAssertEqual(model.conversationEntries.map(\.text), ["pwd", "/home/reader"])
        XCTAssertEqual(model.shellPromptContext, "reader@host:~$")
    }

    func testNoOSCShellPreservesPerLineFallback() {
        let model = TerminalPresentationModel()
        _ = model.process(
            TerminalPresentationFixtures.empty(revision: 0),
            sessionState: .connected
        )
        _ = model.process(
            TerminalPresentationFixtures.snapshot(
                revision: 1,
                viewport: ["one", "two", ""],
                cursorRow: 2,
                rows: TerminalPresentationFixtures.defaultRows
            ),
            sessionState: .connected
        )
        XCTAssertEqual(model.conversationEntries.map(\.text), ["one", "two"])
    }

    func testAlternateScreenBehaviorRemainsUnchangedWithShellSemantics() {
        let model = TerminalPresentationModel()
        _ = model.process(
            TerminalPresentationFixtures.snapshot(
                revision: 1,
                viewport: ["shell history", ""],
                cursorRow: 1,
                semantics: [[.output], []],
                rows: TerminalPresentationFixtures.defaultRows
            ),
            sessionState: .connected
        )
        let entered = model.process(
            TerminalPresentationFixtures.snapshot(
                revision: 2,
                viewport: ["vim buffer", ""],
                cursorRow: 0,
                isAlternateScreen: true,
                semantics: [[.output], []],
                rows: TerminalPresentationFixtures.defaultRows
            ),
            sessionState: .connected
        )
        XCTAssertTrue(entered.events.contains(.alternateScreenEntered))
        XCTAssertEqual(model.conversationEntries.map(\.text), ["shell history"])
        XCTAssertEqual(model.alternateScreenLines.map(\.text), ["vim buffer"])
    }
}
