import XCTest
@testable import FarRelay

final class ReliabilityFunctionKeyTests: XCTestCase {
    func testRawHIDFunctionRowMapsF1ThroughF12() {
        for usage in HIDFunctionKeyForwardingPolicy.firstUsage...HIDFunctionKeyForwardingPolicy.lastUsage {
            XCTAssertEqual(
                HIDFunctionKeyForwardingPolicy.vk(forKeyboardUsage: usage),
                VK.f1 + UInt16(usage - HIDFunctionKeyForwardingPolicy.firstUsage)
            )
        }
    }

    func testNonFunctionHIDUsageIsNotForwardedByTheFallback() {
        XCTAssertNil(HIDFunctionKeyForwardingPolicy.vk(forKeyboardUsage: 0x04))
        XCTAssertNil(HIDFunctionKeyForwardingPolicy.vk(forKeyboardUsage: 0x46))
    }
}
