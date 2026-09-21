import XCTest
@testable import FarRelay

final class ControllerModesTests: XCTestCase {
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

    func testQuickNavigationCategoriesAndQuickBarAreStable() {
        var rotor = QuickNavigationEngine()
        XCTAssertEqual(rotor.toggle(), "Quick Navigation. Quick Bar. Show Desktop.")
        XCTAssertEqual(rotor.category, .quickBar)
        XCTAssertNil(rotor.category.key)
        XCTAssertEqual(rotor.nextQuickBarAction(), "NVDA Menu")
        XCTAssertEqual(rotor.previousQuickBarAction(), "Show Desktop")
        XCTAssertEqual(rotor.nextCategory(), "Headings")
        XCTAssertEqual(rotor.category.key, .h)
        XCTAssertEqual(rotor.nextCategory(), "Links")
        XCTAssertEqual(rotor.category.key, .k)
        XCTAssertEqual(rotor.previousCategory(), "Headings")
        XCTAssertEqual(rotor.previousCategory(), "Quick Bar. Show Desktop")
        XCTAssertEqual(rotor.exit(), "Quick Navigation off.")
    }

    func testTextMapperUsesShiftForUppercaseAndCommonPunctuation() {
        XCTAssertEqual(ControllerTextCharacterMapper.action(for: "A"), .init(key: .a, modifiers: [.shift]))
        XCTAssertEqual(ControllerTextCharacterMapper.action(for: "z"), .init(key: .z))
        XCTAssertEqual(ControllerTextCharacterMapper.action(for: " "), .init(key: .space))
        XCTAssertEqual(ControllerTextCharacterMapper.action(for: "?"), .init(key: .slash, modifiers: [.shift]))
        XCTAssertEqual(ControllerTextCharacterMapper.action(for: "{"), .init(key: .leftBracket, modifiers: [.shift]))
        XCTAssertEqual(ControllerTextCharacterMapper.action(for: "!"), .init(key: .digit1, modifiers: [.shift]))
        XCTAssertEqual(ControllerTextCharacterMapper.action(for: "@"), .init(key: .digit2, modifiers: [.shift]))
        XCTAssertEqual(ControllerTextCharacterMapper.action(for: "_"), .init(key: .minus, modifiers: [.shift]))
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
        XCTAssertEqual(profile.action(for: .dpadUp, layerID: "extended"), .keyboard(.init(key: .pageUp)))
    }
}
