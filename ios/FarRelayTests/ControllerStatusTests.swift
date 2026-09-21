import XCTest
@testable import FarRelay

final class ControllerStatusTests: XCTestCase {
    func testDisconnectedStatusNeverInventsBatteryData() {
        let status = ControllerStatusSnapshot.disconnected
        XCTAssertFalse(status.isConnected)
        XCTAssertNil(status.batteryPercent)
        XCTAssertEqual(status.compactBatteryLabel, "No controller")
        XCTAssertEqual(status.accessibilityLabel, "No controller connected")
    }

    func testConnectedControllerWithMissingBatteryReportsUnavailableNotZero() {
        let status = ControllerStatusSnapshot(
            name: "DualSense Wireless Controller",
            batteryPercent: nil,
            batteryState: nil,
            supportsTouchpad: true,
            supportsHaptics: true,
            supportsLight: true
        )
        XCTAssertEqual(status.compactBatteryLabel, "Controller battery unavailable")
        XCTAssertTrue(status.accessibilityLabel.contains("battery unavailable"))
        XCTAssertFalse(status.accessibilityLabel.contains("battery 0 percent"))
    }

    func testBatteryAndCapabilitiesHaveStableAccessibleText() {
        let status = ControllerStatusSnapshot(
            name: "DualSense Wireless Controller",
            batteryPercent: 67,
            batteryState: .discharging,
            supportsTouchpad: true,
            supportsHaptics: true,
            supportsLight: false
        )
        XCTAssertEqual(status.compactBatteryLabel, "Controller battery 67%")
        XCTAssertEqual(status.capabilitiesLabel, "Controller features: touchpad, haptics")
        XCTAssertTrue(status.accessibilityLabel.contains("battery 67 percent"))
        XCTAssertTrue(status.accessibilityLabel.contains("discharging"))
        XCTAssertTrue(status.accessibilityLabel.contains("touchpad, haptics"))
    }

    func testBatteryPercentageIsRoundedAndClamped() {
        XCTAssertEqual(ControllerStatusSnapshot.percent(fromBatteryLevel: -0.2), 0)
        XCTAssertEqual(ControllerStatusSnapshot.percent(fromBatteryLevel: 0.674), 67)
        XCTAssertEqual(ControllerStatusSnapshot.percent(fromBatteryLevel: 0.676), 68)
        XCTAssertEqual(ControllerStatusSnapshot.percent(fromBatteryLevel: 1.2), 100)
    }
}
