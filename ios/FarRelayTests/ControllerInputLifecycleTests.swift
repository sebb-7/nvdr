import XCTest
@testable import FarRelay

final class ControllerInputLifecycleTests: XCTestCase {
    func testPressHoldRepeatAndReleaseAreBalanced() {
        var state = ControllerInputLifecycle()

        XCTAssertEqual(state.receive(.dpadDown, pressed: true, at: 10), [.pressed(.dpadDown)])
        XCTAssertEqual(state.receive(.dpadDown, pressed: true, at: 10.1), [])
        XCTAssertEqual(state.repeatEvents(at: 10.34), [])
        XCTAssertEqual(state.repeatEvents(at: 10.35), [.repeated(.dpadDown)])
        XCTAssertEqual(state.repeatEvents(at: 10.40), [])
        XCTAssertEqual(state.repeatEvents(at: 10.43), [.repeated(.dpadDown)])
        XCTAssertEqual(state.receive(.dpadDown, pressed: false, at: 10.44), [.released(.dpadDown)])
        XCTAssertEqual(state.repeatEvents(at: 11), [])
    }

    func testReleaseAllUsesStableControllerInputOrder() {
        var state = ControllerInputLifecycle()
        _ = state.receive(.triangle, pressed: true, at: 0)
        _ = state.receive(.dpadUp, pressed: true, at: 0)

        XCTAssertEqual(state.releaseAll(), [.released(.dpadUp), .released(.triangle)])
        XCTAssertEqual(state.releaseAll(), [])
    }

    func testStickUsesDeadzoneAndHysteresis() {
        var stick = ControllerStickDirectionClassifier(
            left: .leftStickLeft, right: .leftStickRight,
            up: .leftStickUp, down: .leftStickDown
        )

        XCTAssertEqual(stick.update(x: 0.64, y: 0, at: 0), [])
        XCTAssertEqual(stick.update(x: 0.65, y: 0, at: 0.1), [.pressed(.leftStickRight)])
        XCTAssertEqual(stick.update(x: 0.50, y: 0, at: 0.2), [])
        XCTAssertEqual(stick.update(x: 0.44, y: 0, at: 0.3), [.released(.leftStickRight)])
        XCTAssertEqual(stick.update(x: -0.80, y: 0.90, at: 0.4), [.pressed(.leftStickLeft), .pressed(.leftStickUp)])
    }
}
