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
        let ranges: [(first: Int, count: Int, firstVK: UInt16)] = [
            (Int(UIKeyboardHIDUsage.keyboardF1.rawValue), 12, VK.f1),
            (Int(UIKeyboardHIDUsage.keyboardF13.rawValue), 12, VK.f1 + 12)
        ]

        for range in ranges {
            for offset in 0..<range.count {
                XCTAssertEqual(
                    HIDToVK.functionVK(forKeyboardUsage: range.first + offset),
                    range.firstVK + UInt16(offset)
                )
            }
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
