import XCTest
@testable import FarRelay

final class ControllerModesTests: XCTestCase {
    func testHoldUsesExtendedOnlyWhileOptionsIsHeld() {
        var engine = ControllerLayerEngine()
        engine.press(layerID: "extended", at: 1)
        XCTAssertEqual(engine.layerForAction(at: 1.1), "extended")
        engine.release(layerID: "extended", at: 1.2)
        XCTAssertNil(engine.layerForAction(at: 1.3))
    }

    func testTapIsOneShotAndDoubleTapLocks() {
        var engine = ControllerLayerEngine()
        engine.press(layerID: "extended", at: 1)
        engine.release(layerID: "extended", at: 1.1)
        XCTAssertEqual(engine.layerForAction(at: 1.2), "extended")
        XCTAssertNil(engine.layerForAction(at: 1.3))

        engine.press(layerID: "extended", at: 2)
        engine.release(layerID: "extended", at: 2.1)
        engine.press(layerID: "extended", at: 2.2)
        engine.release(layerID: "extended", at: 2.3)
        XCTAssertEqual(engine.layerForAction(at: 2.4), "extended")
        XCTAssertEqual(engine.layerForAction(at: 2.5), "extended")
        engine.press(layerID: "extended", at: 2.6)
        XCTAssertNil(engine.layerForAction(at: 2.7))
    }

    func testQuickNavigationCategoriesAndKeyboardShimsAreStable() {
        var rotor = QuickNavigationEngine()
        XCTAssertEqual(rotor.toggle(), "Quick Navigation. Headings.")
        XCTAssertEqual(rotor.category.key, .h)
        XCTAssertEqual(rotor.nextCategory(), "Links")
        XCTAssertEqual(rotor.category.key, .k)
        XCTAssertEqual(rotor.previousCategory(), "Headings")
        XCTAssertEqual(rotor.exit(), "Quick Navigation off.")
    }

    func testTextMapperUsesShiftForUppercaseAndRejectsUnicode() {
        XCTAssertEqual(ControllerTextCharacterMapper.action(for: "A"), .init(key: .a, modifiers: [.shift]))
        XCTAssertEqual(ControllerTextCharacterMapper.action(for: "z"), .init(key: .z))
        XCTAssertEqual(ControllerTextCharacterMapper.action(for: " "), .init(key: .space))
        XCTAssertNil(ControllerTextCharacterMapper.action(for: "é"))
    }

    func testNewDefaultContainsPracticalBaseAndExtendedBindings() {
        let profile = ControllerProfile.newDefault()
        XCTAssertEqual(profile.action(for: .leftShoulder), .keyboard(.init(key: .tab)))
        XCTAssertEqual(profile.action(for: .options), .layer(.init()))
        XCTAssertEqual(profile.action(for: .create), .quickNavigation(.toggle))
        XCTAssertEqual(profile.action(for: .touchpadPress), .farRelay(.textMode))
        XCTAssertEqual(profile.action(for: .dpadUp, layerID: "extended"), .keyboard(.init(key: .pageUp)))
    }
}
