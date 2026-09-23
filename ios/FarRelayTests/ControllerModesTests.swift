import XCTest
@testable import FarRelay

final class ControllerModesTests: XCTestCase {
    func testControllerInputPresentationUsesOneDeterministicModal() {
        XCTAssertNil(
            ControllerInputPresentation.active(
                textModeActive: false,
                quickCommandModeActive: false
            )
        )
        XCTAssertEqual(
            ControllerInputPresentation.active(
                textModeActive: true,
                quickCommandModeActive: false
            ),
            .textMode
        )
        XCTAssertEqual(
            ControllerInputPresentation.active(
                textModeActive: false,
                quickCommandModeActive: true
            ),
            .quickCommandMode
        )
    }

    func testTextModeReturnRequestsSubmitAndExit() {
        XCTAssertTrue(TextModeInputPolicy.requestsSubmitAndExit(replacementText: "\n"))
        XCTAssertTrue(TextModeInputPolicy.requestsSubmitAndExit(replacementText: "\r"))
        XCTAssertFalse(TextModeInputPolicy.requestsSubmitAndExit(replacementText: "a"))
    }

    func testHoldUsesExtendedOnlyWhileOptionsIsHeld() {
        var engine = ControllerLayerEngine()
        engine.press(layerID: "extended", at: 1)
        XCTAssertEqual(engine.layerForAction(), "extended")
        engine.release(layerID: "extended", at: 1.2)
        XCTAssertNil(engine.layerForAction())
    }

    func testTapIsOneShotAndDoubleTapLocks() {
        var engine = ControllerLayerEngine()
        engine.press(layerID: "extended", at: 1)
        engine.release(layerID: "extended", at: 1.1)
        XCTAssertEqual(engine.layerForAction(), "extended")
        XCTAssertNotNil(engine.consumeOneShotAfterResolvedAction())
        XCTAssertNil(engine.layerForAction())

        engine.press(layerID: "extended", at: 2)
        engine.release(layerID: "extended", at: 2.1)
        engine.press(layerID: "extended", at: 2.2)
        engine.release(layerID: "extended", at: 2.3)
        XCTAssertEqual(engine.layerForAction(), "extended")
        XCTAssertEqual(engine.layerForAction(), "extended")
        engine.press(layerID: "extended", at: 2.6)
        XCTAssertNil(engine.layerForAction())
    }

    func testQuickNavigationCategoriesQuickBarAndProfilesAreStable() {
        var rotor = QuickNavigationEngine()
        let quickBar = QuickBarEntry.recommended
        let first = ControllerProfile.newDefault(name: "Desktop")
        let second = ControllerProfile.newDefault(name: "Hearthstone")
        let profiles = [first, second]

        XCTAssertTrue(rotor.isActive)
        XCTAssertEqual(rotor.category, .quickBar)
        XCTAssertNil(rotor.category.key)
        XCTAssertEqual(rotor.currentSectionAnnouncement(quickBar: quickBar, profiles: profiles), "Quick Bar. Windows+D")
        XCTAssertEqual(rotor.nextQuickBarAction(in: quickBar), "NVDA modifier+N")
        XCTAssertEqual(rotor.previousQuickBarAction(in: quickBar), "Windows+D")

        XCTAssertEqual(rotor.nextCategory(), "Profiles")
        rotor.synchronizeProfileSelection(profiles: profiles, activeProfileID: first.id)
        XCTAssertEqual(rotor.currentSectionAnnouncement(quickBar: quickBar, profiles: profiles), "Profiles. Desktop")
        XCTAssertEqual(rotor.nextProfile(in: profiles), "Hearthstone")
        XCTAssertEqual(rotor.previousProfile(in: profiles), "Desktop")

        XCTAssertEqual(rotor.nextCategory(), "Editing")
        XCTAssertNil(rotor.category.key)
        XCTAssertEqual(rotor.currentSectionAnnouncement(quickBar: quickBar, profiles: profiles), "Editing. Select All")
        XCTAssertEqual(rotor.nextEditingAction(), "Copy")
        XCTAssertEqual(rotor.previousEditingAction(), "Select All")

        XCTAssertEqual(rotor.nextCategory(), "Headings")
        XCTAssertEqual(rotor.category.key, .h)
        XCTAssertEqual(rotor.nextCategory(), "Links")
        XCTAssertEqual(rotor.category.key, .k)
        XCTAssertEqual(rotor.exit(), "Quick Navigation off.")
    }

    func testQuickNavigationReportsRotorWrapBoundaries() {
        var rotor = QuickNavigationEngine()
        XCTAssertTrue(rotor.isActive)

        let backwards = rotor.previousCategoryChange()
        XCTAssertTrue(backwards.wrapped)
        XCTAssertEqual(rotor.category, .lists)

        let forwards = rotor.nextCategoryChange()
        XCTAssertTrue(forwards.wrapped)
        XCTAssertEqual(rotor.category, .quickBar)

        let ordinary = rotor.nextCategoryChange()
        XCTAssertFalse(ordinary.wrapped)
        XCTAssertEqual(rotor.category, .profiles)
    }

    func testCustomRotorOrderDrivesCategoryTraversal() {
        var rotor = QuickNavigationEngine()
        let order: [QuickNavigationCategory] = [
            .quickBar, .headings, .profiles, .editing, .links, .formControls,
            .editFields, .buttons, .landmarks, .tables, .lists
        ]

        XCTAssertEqual(rotor.nextCategory(in: order), "Headings")
        XCTAssertEqual(rotor.nextCategory(in: order), "Profiles")
        XCTAssertEqual(rotor.nextCategory(in: order), "Editing")
    }

    func testEditingRotorActionsMapToExpectedWindowsChords() {
        XCTAssertEqual(QuickNavigationEditingAction.selectAll.keyboardAction, .init(key: .a, modifiers: [.control]))
        XCTAssertEqual(QuickNavigationEditingAction.paste.keyboardAction, .init(key: .v, modifiers: [.control]))
        XCTAssertEqual(QuickNavigationEditingAction.redo.keyboardAction, .init(key: .y, modifiers: [.control]))
    }

    func testControllerDeviceStatusIsAccessibleAndTruthful() {
        XCTAssertEqual(
            ControllerDeviceStatus(
                name: "DualSense",
                batteryPercent: 67,
                batteryStateLabel: "Charging",
                supportsHaptics: true,
                supportsTouchpad: true
            ).compactLabel,
            "DualSense · Battery 67 percent · Charging · Haptics · Touchpad"
        )
        XCTAssertEqual(
            ControllerDeviceStatus(
                name: "Controller",
                batteryPercent: nil,
                batteryStateLabel: nil,
                supportsHaptics: false,
                supportsTouchpad: false
            ).compactLabel,
            "Controller · Battery unavailable"
        )
    }

    func testTouchpadRotorGestureRequiresHorizontalThresholdAndConsumesOneStep() {
        var gesture = TouchpadRotorGesture()
        gesture.begin(x: -0.4)
        XCTAssertNil(gesture.move(x: -0.2))
        XCTAssertEqual(gesture.move(x: 0.1), 1)
        XCTAssertNil(gesture.move(x: 0.8))
        gesture.end()

        gesture.begin(x: 0.5)
        XCTAssertEqual(gesture.move(x: 0.0), -1)
        gesture.end()
    }

    func testTouchpadRotorGestureRequiresFreshFingerContactForEveryStep() {
        var gesture = TouchpadRotorGesture()

        XCTAssertNil(gesture.move(x: 0.9))

        gesture.begin(x: -0.6)
        XCTAssertNil(gesture.move(x: -0.4))
        XCTAssertNil(gesture.move(x: -0.3))
        XCTAssertEqual(gesture.move(x: 0.0), 1)

        // Exactly one rotor step is allowed for this finger contact.
        XCTAssertNil(gesture.move(x: 0.9))
        XCTAssertNil(gesture.move(x: -0.9))
        gesture.end()

        // A lift resets the recognizer. Motion alone stays inert until a fresh touch.
        XCTAssertNil(gesture.move(x: -0.9))
        gesture.begin(x: 0.6)
        XCTAssertEqual(gesture.move(x: 0.0), -1)
        XCTAssertNil(gesture.move(x: -0.8))
        gesture.end()
    }

    func testTouchpadRotorEndAlwaysRequiresANewBegin() {
        var gesture = TouchpadRotorGesture()
        gesture.begin(x: -0.6)
        gesture.end()

        XCTAssertNil(gesture.move(x: 0.6))

        gesture.begin(x: -0.6)
        XCTAssertEqual(gesture.move(x: 0.0), 1)
    }

    func testTextMapperHasCompleteUSAsciiPunctuationTable() {
        XCTAssertEqual(ControllerTextCharacterMapper.action(for: "A"), .init(key: .a, modifiers: [.shift]))
        XCTAssertEqual(ControllerTextCharacterMapper.action(for: "z"), .init(key: .z))
        XCTAssertEqual(ControllerTextCharacterMapper.action(for: " "), .init(key: .space))
        let cases: [(Character, KeyboardAction)] = [
            ("/", .init(key: .slash)), ("?", .init(key: .slash, modifiers: [.shift])),
            ("[", .init(key: .leftBracket)), ("{", .init(key: .leftBracket, modifiers: [.shift])),
            ("]", .init(key: .rightBracket)), ("}", .init(key: .rightBracket, modifiers: [.shift])),
            ("\\", .init(key: .backslash)), ("|", .init(key: .backslash, modifiers: [.shift])),
            (";", .init(key: .semicolon)), (":", .init(key: .semicolon, modifiers: [.shift])),
            ("'", .init(key: .quote)), ("\"", .init(key: .quote, modifiers: [.shift])),
            (",", .init(key: .comma)), ("<", .init(key: .comma, modifiers: [.shift])),
            (".", .init(key: .period)), (">", .init(key: .period, modifiers: [.shift])),
            ("`", .init(key: .grave)), ("~", .init(key: .grave, modifiers: [.shift])),
            ("-", .init(key: .minus)), ("_", .init(key: .minus, modifiers: [.shift])),
            ("=", .init(key: .equal)), ("+", .init(key: .equal, modifiers: [.shift])),
            ("1", .init(key: .digit1)), ("!", .init(key: .digit1, modifiers: [.shift])),
            ("2", .init(key: .digit2)), ("@", .init(key: .digit2, modifiers: [.shift])),
            ("3", .init(key: .digit3)), ("#", .init(key: .digit3, modifiers: [.shift])),
            ("4", .init(key: .digit4)), ("$", .init(key: .digit4, modifiers: [.shift])),
            ("5", .init(key: .digit5)), ("%", .init(key: .digit5, modifiers: [.shift])),
            ("6", .init(key: .digit6)), ("^", .init(key: .digit6, modifiers: [.shift])),
            ("7", .init(key: .digit7)), ("&", .init(key: .digit7, modifiers: [.shift])),
            ("8", .init(key: .digit8)), ("*", .init(key: .digit8, modifiers: [.shift])),
            ("9", .init(key: .digit9)), ("(", .init(key: .digit9, modifiers: [.shift])),
            ("0", .init(key: .digit0)), (")", .init(key: .digit0, modifiers: [.shift])),
        ]
        for (character, expected) in cases {
            XCTAssertEqual(ControllerTextCharacterMapper.action(for: character), expected, "\(character)")
        }
        XCTAssertNil(ControllerTextCharacterMapper.action(for: "é"))
    }

    func testTextMirrorSessionNeverDeletesACharacterThatWasNotMirrored() {
        var session = TextModeMirrorSession()
        session.append("a", mirrored: true)
        session.append("é", mirrored: false)
        XCTAssertEqual(session.deleteSuffix(count: 1), 0)
        XCTAssertEqual(session.text, "a")
        XCTAssertEqual(session.deleteSuffix(count: 1), 1)
    }

    func testRemoteBackspaceMarksKnownRemoteCharacterToPreventADuplicateDelete() {
        var session = TextModeMirrorSession()
        session.append("a", mirrored: true)
        XCTAssertTrue(session.remoteBackspace())
        XCTAssertEqual(session.text, "")
        XCTAssertEqual(session.deleteSuffix(count: 1), 0)
    }

    func testNewDefaultContainsPracticalBaseAndExtendedBindings() {
        let profile = ControllerProfile.newDefault()
        XCTAssertEqual(profile.action(for: .leftShoulder), .keyboard(.init(key: .tab)))
        XCTAssertEqual(profile.action(for: .rightShoulder), .keyboard(.init(key: .w, modifiers: [.control])))
        XCTAssertEqual(profile.action(for: .options), .layer(.init()))
        XCTAssertEqual(profile.action(for: .create), .quickNavigation(.toggle))
        XCTAssertEqual(profile.action(for: .touchpadPress), .farRelay(.textMode))
        XCTAssertEqual(profile.action(for: .home), .farRelay(.nextProfile))
        XCTAssertEqual(profile.action(for: .cross, layerID: "extended"), .farRelay(.repeatLastQuickBar))
        XCTAssertEqual(profile.action(for: .home, layerID: "extended"), .farRelay(.previousProfile))
        XCTAssertEqual(profile.action(for: .dpadUp, layerID: "extended"), .keyboard(.init(key: .pageUp)))
        XCTAssertFalse(profile.quickBar.isEmpty)
    }
}
