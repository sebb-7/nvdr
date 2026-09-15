import UIKit
import XCTest
@testable import FarRelay

final class RemoteInputMappingTests: XCTestCase {
    func testEveryPublicFunctionKeyMapsToItsWindowsVK() {
        for (offset, input) in ReservedKeyForwardingPolicy.functionInputs.enumerated() {
            XCTAssertEqual(
                ReservedKeyForwardingPolicy.vk(forInput: input),
                VK.f1 + UInt16(offset),
                "F\(offset + 1) must retain its logical remote representation."
            )
        }
    }

    func testRawHIDFunctionKeysCoverF1ThroughF24() {
        let first = Int(UIKeyboardHIDUsage.keyboardF1.rawValue)
        for offset in 0..<24 {
            XCTAssertEqual(HIDToVK.functionVK(forKeyboardUsage: first + offset), VK.f1 + UInt16(offset))
        }
    }

    func testFunctionChordsHaveBalancedLogicalTransitions() {
        let transitions = ReservedKeyForwardingPolicy.transitions(
            for: UIKeyCommand.f1,
            modifierFlags: [.control, .alternate, .shift],
            optionMapping: .alt,
            commandMapping: .alt
        )
        XCTAssertEqual(
            transitions?.map { "\($0.vk):\($0.pressed)" },
            ["17:true", "164:true", "16:true", "112:true", "112:false", "16:false", "164:false", "17:false"]
        )
    }

    func testNavigationKeysHaveLogicalRemoteRepresentations() {
        let expected: [(String, UInt16)] = [
            (UIKeyCommand.inputUpArrow, VK.up),
            (UIKeyCommand.inputDownArrow, VK.down),
            (UIKeyCommand.inputLeftArrow, VK.left),
            (UIKeyCommand.inputRightArrow, VK.right),
            (UIKeyCommand.inputEscape, VK.escape)
        ]
        for (input, vk) in expected {
            XCTAssertEqual(ReservedKeyForwardingPolicy.vk(forInput: input), vk)
        }
    }
}
