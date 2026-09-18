import GameController
import UIKit
import XCTest
@testable import FarRelay

final class FunctionKeyCapturePolicyTests: XCTestCase {
    func testCommandFallbackCoversTheRequiredF1ThroughF12Mapping() {
        XCTAssertEqual(CommandFunctionKeyFallback.mappings.map(\.virtualKey), Array(VK.f1...(VK.f1 + 11)))
        XCTAssertEqual(CommandFunctionKeyFallback.mapping(for: .keyboard1)?.virtualKey, VK.f1)
        XCTAssertEqual(CommandFunctionKeyFallback.mapping(for: .keyboard0)?.virtualKey, VK.f1 + 9)
        XCTAssertEqual(CommandFunctionKeyFallback.mapping(for: .keyboardHyphen)?.virtualKey, VK.f1 + 10)
        XCTAssertEqual(CommandFunctionKeyFallback.mapping(for: .keyboardEqualSign)?.virtualKey, VK.f1 + 11)
    }

    func testCommandFallbackStripsCommandAndBalancesPreservedModifiers() {
        let transitions = CommandFunctionKeyFallback.transitions(
            virtualKey: VK.f1 + 3,
            modifierFlags: [.command, .alternate]
        )
        XCTAssertEqual(
            transitions.map { "\($0.vk):\($0.pressed)" },
            ["18:true", "115:true", "115:false", "18:false"]
        )
        XCTAssertFalse(transitions.contains { $0.vk == VK.lwin || $0.vk == VK.rwin })
    }

    func testFallbackPreservesControlAltAndShiftInStableOrder() {
        let transitions = CommandFunctionKeyFallback.transitions(
            virtualKey: VK.f1 + 9,
            modifierFlags: [.command, .control, .alternate, .shift]
        )
        XCTAssertEqual(
            transitions.map { "\($0.vk):\($0.pressed)" },
            ["17:true", "18:true", "16:true", "121:true", "121:false", "16:false", "18:false", "17:false"]
        )
    }

    func testEveryGameControllerFunctionKeyHasTheExpectedWindowsVirtualKey() {
        let keyCodes: [GCKeyCode] = [.F1, .F2, .F3, .F4, .F5, .F6, .F7, .F8, .F9, .F10, .F11, .F12]
        XCTAssertEqual(
            keyCodes.compactMap { GameControllerFunctionKeyMapping.virtualKey(for: $0) },
            Array(VK.f1...(VK.f1 + 11))
        )
        XCTAssertNil(GameControllerFunctionKeyMapping.virtualKey(for: .F13))
    }

    func testGameControllerLifecycleReleasesPressedKeysOnDisconnect() {
        var state = GameControllerFunctionKeyState()
        state.receive(virtualKey: VK.f1, pressed: true)
        state.receive(virtualKey: VK.f1 + 3, pressed: true)
        state.receive(virtualKey: VK.f1, pressed: false)
        XCTAssertEqual(state.releaseAllOnDisconnect(), [VK.f1 + 3])
        XCTAssertTrue(state.activeVirtualKeys.isEmpty)
    }

    func testDuplicateGateSuppressesOnlyCrossSourceDuplicates() {
        var gate = FunctionKeyDuplicateGate()
        let now = Date(timeIntervalSince1970: 10)
        XCTAssertFalse(gate.suppresses(virtualKey: VK.f1, pressed: true, source: .gameController, now: now))
        XCTAssertTrue(gate.suppresses(virtualKey: VK.f1, pressed: true, source: .rawPress, now: now.addingTimeInterval(0.01)))
        XCTAssertFalse(gate.suppresses(virtualKey: VK.f1, pressed: true, source: .rawPress, now: now.addingTimeInterval(0.20)))
    }

    func testFallbackRepeatPolicySuppressesOnlyTheImmediateDuplicate() {
        var gate = FunctionKeyDuplicateGate()
        let now = Date(timeIntervalSince1970: 10)
        XCTAssertFalse(gate.suppressesFallback(virtualKey: VK.f1, now: now))
        XCTAssertTrue(gate.suppressesFallback(virtualKey: VK.f1, now: now.addingTimeInterval(0.01)))
        XCTAssertFalse(gate.suppressesFallback(virtualKey: VK.f1, now: now.addingTimeInterval(0.20)))
    }

    func testFallbackRegistrationsDoNotRequireASequentialMode() {
        XCTAssertEqual(CommandFunctionKeyFallback.keyCommandRegistrations.count, 96)
        XCTAssertTrue(CommandFunctionKeyFallback.keyCommandRegistrations.allSatisfy { $0.modifiers.contains(.command) })
    }
}
