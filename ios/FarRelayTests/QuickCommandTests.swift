import XCTest
@testable import FarRelay

final class QuickCommandTests: XCTestCase {
    func testSingleChordParsesWithoutAnyMacroSemantics() throws {
        let command = try QuickCommandParser.parse("ctrl+v")

        XCTAssertEqual(
            command,
            QuickCommand(steps: [
                .chord(.init(keys: [
                    .modifier(.control),
                    .key(.character("v")),
                ])),
            ])
        )
        XCTAssertEqual(command.spokenDescription, "Control plus V")
    }

    func testCommaSeparatesOneShotStepsAndUnknownWordsBecomeLiteralText() throws {
        let command = try QuickCommandParser.parse("win+r,powershell,enter")

        XCTAssertEqual(
            command.steps,
            [
                .chord(.init(keys: [.modifier(.windows), .key(.character("r"))])),
                .text("powershell"),
                .chord(.init(keys: [.key(.named(.enter))])),
            ]
        )
        XCTAssertEqual(
            command.spokenDescription,
            "Windows plus R. Then Type powershell. Then Enter"
        )
    }

    func testLiteralTextKeepsUsefulPunctuationWithoutQuotesOrBraces() throws {
        let command = try QuickCommandParser.parse("ctrl+l,github.com/test?a=1&b=2,enter")

        XCTAssertEqual(command.steps[1], .text("github.com/test?a=1&b=2"))
    }

    func testFourSimultaneousKeysAreAllowed() throws {
        let command = try QuickCommandParser.parse("ctrl+shift+delete+escape")

        XCTAssertEqual(
            command.steps,
            [
                .chord(.init(keys: [
                    .modifier(.control),
                    .modifier(.shift),
                    .key(.named(.delete)),
                    .key(.named(.escape)),
                ])),
            ]
        )
    }

    func testFiveSimultaneousKeysFailClosed() {
        XCTAssertThrowsError(
            try QuickCommandParser.parse("ctrl+shift+alt+delete+escape")
        ) { error in
            XCTAssertEqual(
                error as? QuickCommandParseError,
                .tooManyChordKeys(position: 1, maximum: 4)
            )
        }
    }

    func testAliasesResolveToTheSameTypedKeys() throws {
        XCTAssertEqual(
            try QuickCommandParser.parse("control+supr"),
            try QuickCommandParser.parse("ctrl+delete")
        )
        XCTAssertEqual(
            try QuickCommandParser.parse("windows+r"),
            try QuickCommandParser.parse("win+r")
        )
        XCTAssertEqual(
            try QuickCommandParser.parse("command+escape"),
            try QuickCommandParser.parse("cmd+esc")
        )
        XCTAssertEqual(
            try QuickCommandParser.parse("option+pgdn"),
            try QuickCommandParser.parse("opt+pagedown")
        )
        XCTAssertEqual(
            try QuickCommandParser.parse("page up"),
            try QuickCommandParser.parse("pgup")
        )
    }

    func testAliasesAreCaseInsensitiveAndWhitespaceTolerant() throws {
        XCTAssertEqual(
            try QuickCommandParser.parse(" Control + Shift + ESC "),
            try QuickCommandParser.parse("ctrl+shift+escape")
        )
    }

    func testFunctionKeysAndSingleKeysParseAsChords() throws {
        let command = try QuickCommandParser.parse("f24,tab,left")

        XCTAssertEqual(
            command.steps,
            [
                .chord(.init(keys: [.key(.function(24))])),
                .chord(.init(keys: [.key(.named(.tab))])),
                .chord(.init(keys: [.key(.named(.left))])),
            ]
        )
    }

    func testUnknownTokenInsideAChordIsAnErrorNotLiteralText() {
        XCTAssertThrowsError(
            try QuickCommandParser.parse("ctrl+paste")
        ) { error in
            XCTAssertEqual(
                error as? QuickCommandParseError,
                .unknownChordKey("paste", position: 1)
            )
        }
    }

    func testDuplicateAliasesCannotCreateDuplicateHeldKeys() {
        XCTAssertThrowsError(
            try QuickCommandParser.parse("ctrl+control+v")
        ) { error in
            XCTAssertEqual(
                error as? QuickCommandParseError,
                .duplicateChordKey("control", position: 1)
            )
        }
    }

    func testModifierOnlyChordIsRejected() {
        XCTAssertThrowsError(
            try QuickCommandParser.parse("ctrl+shift")
        ) { error in
            XCTAssertEqual(
                error as? QuickCommandParseError,
                .modifierOnlyChord(position: 1)
            )
        }
    }

    func testEmptyStepsAndBrokenChordsFailClosed() {
        XCTAssertThrowsError(
            try QuickCommandParser.parse("win+r,,enter")
        ) { error in
            XCTAssertEqual(
                error as? QuickCommandParseError,
                .emptyStep(position: 2)
            )
        }

        XCTAssertThrowsError(
            try QuickCommandParser.parse("ctrl++v")
        ) { error in
            XCTAssertEqual(
                error as? QuickCommandParseError,
                .emptyChordKey(position: 1)
            )
        }
    }

    func testSequenceLengthIsDeliberatelySmall() {
        XCTAssertNoThrow(
            try QuickCommandParser.parse("win+r,powershell,enter,tab,escape")
        )
        XCTAssertThrowsError(
            try QuickCommandParser.parse("a,b,c,d,e,f")
        ) { error in
            XCTAssertEqual(
                error as? QuickCommandParseError,
                .tooManySteps(maximum: 5)
            )
        }
    }

    func testLiteralTextLengthIsBounded() {
        let tooLong = String(repeating: "a", count: QuickCommandParser.maximumLiteralCharacters + 1)

        XCTAssertThrowsError(
            try QuickCommandParser.parse(tooLong)
        ) { error in
            XCTAssertEqual(
                error as? QuickCommandParseError,
                .literalTextTooLong(position: 1, maximum: 256)
            )
        }
    }

    func testKnownPunctuationNamesRemainAvailableAsKeys() throws {
        let command = try QuickCommandParser.parse("comma,dot,slash")

        XCTAssertEqual(
            command.steps,
            [
                .chord(.init(keys: [.key(.named(.comma))])),
                .chord(.init(keys: [.key(.named(.period))])),
                .chord(.init(keys: [.key(.named(.slash))])),
            ]
        )
    }

    func testReturnRequestsQuickCommandConfirmationInsteadOfEnteringNewline() {
        XCTAssertTrue(QuickCommandTextInputPolicy.requestsConfirmation(replacementText: "\n"))
        XCTAssertTrue(QuickCommandTextInputPolicy.requestsConfirmation(replacementText: "\r"))
        XCTAssertFalse(QuickCommandTextInputPolicy.requestsConfirmation(replacementText: ","))
        XCTAssertFalse(QuickCommandTextInputPolicy.requestsConfirmation(replacementText: "+"))
    }

    func testQuickCommandEditorYieldsFocusToConfirmationAlert() {
        XCTAssertTrue(
            QuickCommandEditorFocusPolicy.shouldOwnFocus(isShowingConfirmation: false)
        )
        XCTAssertFalse(
            QuickCommandEditorFocusPolicy.shouldOwnFocus(isShowingConfirmation: true)
        )
    }

    func testEmptyInputHasAUsefulError() {
        XCTAssertThrowsError(
            try QuickCommandParser.parse("   ")
        ) { error in
            XCTAssertEqual(error as? QuickCommandParseError, .emptyInput)
            XCTAssertEqual((error as? QuickCommandParseError)?.message, "Enter a quick command.")
        }
    }
}
