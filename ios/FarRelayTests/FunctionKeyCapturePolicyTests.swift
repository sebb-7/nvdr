import GameController
import UIKit
import XCTest
@testable import FarRelay

final class FunctionKeyCapturePolicyTests: XCTestCase {
    func testPhysicalFunctionRowUsesUIKitPriorityPlusGameControllerFallback() {
        XCTAssertTrue(PhysicalFunctionRowCapturePolicy.installsGameControllerCapture)

        let registrations = PhysicalFunctionRowCapturePolicy.priorityRegistrations
        XCTAssertEqual(registrations.count, ReservedKeyForwardingPolicy.registrations.count)
        XCTAssertEqual(
            Set(registrations.map(\.input)).intersection(Set(ReservedKeyForwardingPolicy.functionInputs)),
            Set(ReservedKeyForwardingPolicy.functionInputs)
        )
    }

    func testCommandNumberFallbackIsNotPartOfPriorityRegistrationSurface() {
        let priorityInputs = Set(
            PhysicalFunctionRowCapturePolicy.priorityRegistrations.map {
                "\($0.input)|\(ReservedKeyForwardingPolicy.modifierFlags(for: $0.modifiers).rawValue)"
            }
        )
        for fallback in CommandFunctionKeyFallback.keyCommandRegistrations {
            let signature = "\(fallback.input)|\(fallback.modifiers.rawValue)"
            XCTAssertFalse(priorityInputs.contains(signature))
        }
    }

    func testCommandFallbackCoversTheRequiredF1ThroughF12Mapping() {
        XCTAssertEqual(CommandFunctionKeyFallback.mappings.map(\.virtualKey), Array(VK.f1...(VK.f1 + 11)))
        XCTAssertEqual(CommandFunctionKeyFallback.mapping(for: .keyboard4)?.virtualKey, VK.f1 + 3)
        XCTAssertEqual(CommandFunctionKeyFallback.mapping(for: .keyboardEqualSign)?.virtualKey, VK.f1 + 11)
    }

    func testProductionTapPlanCommandFourHasOnlyBalancedF4() {
        XCTAssertEqual(plan(VK.f1 + 3, flags: [.command]), ["115:true", "115:false"])
    }

    func testProductionTapPlanPreservesEveryRequiredModifierInOrder() {
        XCTAssertEqual(plan(VK.f1 + 3, flags: [.command, .alternate]), ["18:true", "115:true", "115:false", "18:false"])
        XCTAssertEqual(plan(VK.f1, flags: [.command, .control]), ["17:true", "112:true", "112:false", "17:false"])
        XCTAssertEqual(plan(VK.f1 + 9, flags: [.command, .shift]), ["16:true", "121:true", "121:false", "16:false"])
        XCTAssertEqual(plan(VK.f1 + 3, flags: [.command, .alphaShift]), ["20:true", "115:true", "115:false", "20:false"])
        XCTAssertEqual(plan(VK.f1 + 3, flags: [.command, .alternate, .alphaShift]), ["18:true", "20:true", "115:true", "115:false", "20:false", "18:false"])
    }

    func testProductionTapPlanDoesNotDuplicateOrReleasePhysicallyHeldModifiers() {
        let plan = FunctionKeyTransmissionPlan(
            virtualKey: VK.f1 + 3,
            modifiers: CommandFunctionKeyFallback.preservedModifiers(for: [.command, .alternate, .alphaShift]),
            alreadyPressed: [VK.menu, VK.capital]
        )
        XCTAssertEqual(plan.transitions.map { "\($0.vk):\($0.pressed)" }, ["115:true", "115:false"])
    }

    func testEveryGameControllerFunctionKeyHasTheExpectedWindowsVirtualKey() {
        let keyCodes: [GCKeyCode] = [.F1, .F2, .F3, .F4, .F5, .F6, .F7, .F8, .F9, .F10, .F11, .F12]
        XCTAssertEqual(keyCodes.compactMap { GameControllerFunctionKeyMapping.virtualKey(for: $0) }, Array(VK.f1...(VK.f1 + 11)))
        XCTAssertNil(GameControllerFunctionKeyMapping.virtualKey(for: .F13))
    }

    func testEveryPhysicalFKeyHasOneBalancedTransitionPairAndCrossSourceDeduplication() {
        let firstUsage = Int(UIKeyboardHIDUsage.keyboardF1.rawValue)
        for offset in 0..<12 {
            let virtualKey = VK.f1 + UInt16(offset)
            XCTAssertEqual(HIDToVK.functionVK(forKeyboardUsage: firstUsage + offset), virtualKey)
            XCTAssertEqual(
                FunctionKeyTransmissionPlan(
                    virtualKey: virtualKey,
                    modifiers: [],
                    alreadyPressed: []
                ).transitions.map { "\($0.vk):\($0.pressed)" },
                ["\(virtualKey):true", "\(virtualKey):false"],
                "F\(offset + 1) must produce exactly one down/up pair."
            )

            var gate = FunctionKeyDuplicateGate()
            let now = Date(timeIntervalSince1970: Double(offset))
            XCTAssertFalse(gate.suppresses(
                virtualKey: virtualKey,
                pressed: true,
                source: .rawPress,
                originUsage: firstUsage + offset,
                now: now
            ))
            XCTAssertTrue(gate.suppresses(
                virtualKey: virtualKey,
                pressed: true,
                source: .gameController,
                originUsage: firstUsage + offset,
                now: now.addingTimeInterval(0.01)
            ))
        }
    }

    func testModifierFingerprintMatchesUIKitAndGameControllerRepresentations() {
        let ui = FunctionKeyModifierFingerprint.fromUIKit([.command, .control, .alternate, .shift, .alphaShift])
        let gameController = FunctionKeyModifierFingerprint.fromRemoteModifiers([
            VK.control, VK.menu, VK.shift, VK.capital
        ])
        XCTAssertEqual(ui, gameController)
    }

    func testModifierFingerprintIgnoresCommandForCrossSourceDeduplication() {
        XCTAssertEqual(
            FunctionKeyModifierFingerprint.fromUIKit([.command, .shift]),
            FunctionKeyModifierFingerprint.fromUIKit([.shift])
        )
    }

    func testGameControllerLifecycleReleasesPressedKeysOnDisconnect() {
        var state = GameControllerFunctionKeyState()
        state.receive(virtualKey: VK.f1, pressed: true)
        state.receive(virtualKey: VK.f1 + 3, pressed: true)
        state.receive(virtualKey: VK.f1, pressed: false)
        XCTAssertEqual(state.releaseAllOnDisconnect(), [VK.f1 + 3])
        XCTAssertTrue(state.activeVirtualKeys.isEmpty)
    }

    func testDuplicateGateSuppressesOnlyMatchingCrossSourceAction() {
        var gate = FunctionKeyDuplicateGate()
        let now = Date(timeIntervalSince1970: 10)
        XCTAssertFalse(gate.suppresses(virtualKey: VK.f1, pressed: true, source: .rawPress, modifierFlags: 1, originUsage: 58, now: now))
        XCTAssertTrue(gate.suppresses(virtualKey: VK.f1, pressed: true, source: .gameController, modifierFlags: 1, originUsage: 58, now: now.addingTimeInterval(0.01)))
        XCTAssertFalse(gate.suppresses(virtualKey: VK.f1, pressed: true, source: .gameController, modifierFlags: 1, originUsage: 58, now: now.addingTimeInterval(0.02)))
    }

    func testDuplicateGatePreservesRepeatReleaseModifierChangeDifferentKeyAndSeparateAction() {
        var gate = FunctionKeyDuplicateGate()
        let now = Date(timeIntervalSince1970: 20)
        XCTAssertFalse(gate.suppresses(virtualKey: VK.f1, pressed: true, source: .rawFallback, modifierFlags: 2, originUsage: 33, now: now))
        XCTAssertFalse(gate.suppresses(virtualKey: VK.f1, pressed: true, source: .rawFallback, modifierFlags: 2, originUsage: 33, now: now.addingTimeInterval(0.01)))
        XCTAssertFalse(gate.suppresses(virtualKey: VK.f1, pressed: false, source: .keyCommandFallback, modifierFlags: 2, originUsage: 33, now: now.addingTimeInterval(0.02)))
        XCTAssertFalse(gate.suppresses(virtualKey: VK.f1, pressed: true, source: .keyCommandFallback, modifierFlags: 4, originUsage: 33, now: now.addingTimeInterval(0.03)))
        XCTAssertFalse(gate.suppresses(virtualKey: VK.f1 + 1, pressed: true, source: .keyCommandFallback, modifierFlags: 2, originUsage: 34, now: now.addingTimeInterval(0.04)))
        XCTAssertFalse(gate.suppresses(virtualKey: VK.f1, pressed: true, source: .keyCommandFallback, modifierFlags: 2, originUsage: 33, now: now.addingTimeInterval(0.20)))
    }

    func testKeyboardCaptureRefreshesOnlyWhenBSIModalCloses() {
        XCTAssertFalse(
            KeyboardCaptureModalLifecyclePolicy.shouldRefresh(
                wasActive: false,
                isActive: true
            )
        )
        XCTAssertFalse(
            KeyboardCaptureModalLifecyclePolicy.shouldRefresh(
                wasActive: true,
                isActive: true
            )
        )
        XCTAssertTrue(
            KeyboardCaptureModalLifecyclePolicy.shouldRefresh(
                wasActive: true,
                isActive: false
            )
        )
        XCTAssertFalse(
            KeyboardCaptureModalLifecyclePolicy.shouldRefresh(
                wasActive: false,
                isActive: false
            )
        )
    }

    func testKeyboardCaptureIdentityChangesAfterModalDismissRefresh() {
        let before = KeyboardCaptureIdentity(
            forwardingEnabled: true,
            refreshGeneration: 7
        )
        let after = KeyboardCaptureIdentity(
            forwardingEnabled: true,
            refreshGeneration: 8
        )
        XCTAssertNotEqual(before, after)
    }

    func testFallbackRegistrationsDoNotRequireASequentialMode() {
        XCTAssertEqual(CommandFunctionKeyFallback.keyCommandRegistrations.count, 96)
        XCTAssertTrue(CommandFunctionKeyFallback.keyCommandRegistrations.allSatisfy { $0.modifiers.contains(.command) })
    }

    private func plan(_ virtualKey: UInt16, flags: UIKeyModifierFlags) -> [String] {
        FunctionKeyTransmissionPlan(
            virtualKey: virtualKey,
            modifiers: CommandFunctionKeyFallback.preservedModifiers(for: flags),
            alreadyPressed: []
        ).transitions.map { "\($0.vk):\($0.pressed)" }
    }
}
