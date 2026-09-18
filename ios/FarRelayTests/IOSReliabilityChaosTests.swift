import SwiftUI
import Foundation
import XCTest
@testable import FarRelay

@MainActor
final class IOSReliabilityChaosTests: XCTestCase {
    func testSceneLifecycleNeverReconnectsMerelyBecauseTheAppBecomesActive() {
        XCTAssertTrue(NVDARemoteSceneLifecyclePolicy.shouldSuspendInput(for: .inactive))
        XCTAssertTrue(NVDARemoteSceneLifecyclePolicy.shouldSuspendInput(for: .background))
        XCTAssertFalse(NVDARemoteSceneLifecyclePolicy.shouldSuspendInput(for: .active))
    }

    func testDeterministicInputChaosNeverRetainsKeysAfterOwnershipEnds() {
        var generator = DeterministicGenerator(seed: 0xFA11E1A)
        var input = SSHInputState()
        let keys: [UInt16] = [VK.shift, VK.control, VK.menu, VK.tab, VK.escape, VK.f1, VK.left]

        for _ in 0..<1_000 {
            switch generator.next() % 5 {
            case 0, 1:
                _ = input.command(forKey: keys[Int(generator.next() % UInt64(keys.count))], pressed: true)
            case 2:
                _ = input.command(forKey: keys[Int(generator.next() % UInt64(keys.count))], pressed: false)
            default:
                input.reset()
            }
        }

        input.reset()
        XCTAssertTrue(input.pressedKeys.isEmpty)
        XCTAssertTrue(keys.allSatisfy { input.command(forKey: $0, pressed: false) == nil })
    }

    func testSupportedRemoteKeyDomainDoesNotAliasUnsupportedValues() async {
        let sink = ReliabilityKeySink()
        let target = NVDARemoteIntentTarget(keySink: sink)

        for number in 1...24 {
            guard let key = RemoteKey.function(number) else {
                return XCTFail("F\(number) should be in the RemoteKey domain")
            }
            let result = await target.perform(.sendKey(key))
            if number <= 12 {
                XCTAssertEqual(result, .performed)
            } else {
                XCTAssertEqual(result, .unsupported)
            }
        }
        XCTAssertNil(RemoteKey.function(0))
        XCTAssertNil(RemoteKey.function(25))
    }

    func testMalformedIPCChaosIsBoundedAndNeverBecomesReady() {
        var generator = DeterministicGenerator(seed: 0x1ACF00D)
        for _ in 0..<512 {
            let length = Int(generator.next() % 96)
            let text = String((0..<length).map { _ in
                let scalar = UnicodeScalar(32 + UInt32(generator.next() % 95)) ?? " "
                return Character(String(scalar))
            })
            if case .state(.ready) = IPCParser.parse(text) {
                XCTFail("Only the exact IPC ready frame may make the bridge ready")
            }
        }
        XCTAssertEqual(IPCParser.parse("state ready"), .state(.ready))
    }
}

private struct DeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}

@MainActor
private final class ReliabilityKeySink: RemoteWindowsKeySink {
    var isInputForwardingReady = true
    var activeProfileID: UUID?
    func sendKey(vk: UInt16, pressed: Bool) {}
}
