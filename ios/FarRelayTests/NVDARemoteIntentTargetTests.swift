import Foundation
import XCTest
@testable import FarRelay

@MainActor
final class NVDARemoteIntentTargetTests: XCTestCase {
    func testSemanticNavigationEmitsExactWindowsKeyTransitions() async {
        let sink = FakeWindowsKeySink()
        let target = NVDARemoteIntentTarget(keySink: sink)
        let cases: [(RemoteIntent, [KeyTransition])] = [
            (.nextItem, [.init(VK.tab, true), .init(VK.tab, false)]),
            (.previousItem, [.init(VK.shift, true), .init(VK.tab, true), .init(VK.tab, false), .init(VK.shift, false)]),
            (.activate, [.init(VK.return, true), .init(VK.return, false)]),
            (.cancel, [.init(VK.escape, true), .init(VK.escape, false)]),
            (.nextApplication, [.init(VK.menu, true), .init(VK.tab, true), .init(VK.tab, false), .init(VK.menu, false)]),
            (.previousApplication, [.init(VK.menu, true), .init(VK.shift, true), .init(VK.tab, true), .init(VK.tab, false), .init(VK.shift, false), .init(VK.menu, false)]),
            (.closeWindow, [.init(VK.menu, true), .init(VK.f1 + 3, true), .init(VK.f1 + 3, false), .init(VK.menu, false)]),
            (.showDesktop, [.init(VK.lwin, true), .init(0x44, true), .init(0x44, false), .init(VK.lwin, false)])
        ]

        for (intent, expected) in cases {
            sink.transitions.removeAll()
            let result = await target.perform(intent)
            XCTAssertEqual(result, .performed)
            XCTAssertEqual(sink.transitions, expected, "Unexpected transition order for \(intent)")
        }
    }

    func testOpenStartAndRawChordReleaseEveryModifier() async {
        let sink = FakeWindowsKeySink()
        let target = NVDARemoteIntentTarget(keySink: sink)

        let start = await target.perform(.openStart)
        XCTAssertEqual(start, .performed)
        XCTAssertEqual(sink.transitions, [.init(VK.lwin, true), .init(VK.lwin, false)])

        sink.transitions.removeAll()
        guard let letterC = RemoteKey.letter("c") else {
            XCTFail("C should be a valid neutral remote key.")
            return
        }
        let chord = RemoteChord(modifiers: [.control, .alt], key: letterC)
        let result = await target.perform(.sendChord(chord))
        XCTAssertEqual(result, .performed)
        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.menu, true), .init(VK.control, true), .init(0x43, true), .init(0x43, false),
                .init(VK.control, false), .init(VK.menu, false)
            ]
        )
    }

    func testUnavailableForwardingDoesNotEmitOrEnableInput() async {
        let sink = FakeWindowsKeySink(isInputForwardingReady: false)
        let target = NVDARemoteIntentTarget(keySink: sink)

        let result = await target.perform(.nextItem)

        XCTAssertEqual(result, .unavailable("NVDA input forwarding is unavailable."))
        XCTAssertFalse(sink.isInputForwardingReady)
        XCTAssertTrue(sink.transitions.isEmpty)
    }

    func testUnsupportedRawFunctionKeyDoesNotLeaveModifiersPressed() async {
        guard let function13 = RemoteKey.function(13) else {
            XCTFail("F13 should be a valid neutral remote key.")
            return
        }
        let sink = FakeWindowsKeySink()
        let target = NVDARemoteIntentTarget(keySink: sink)

        let result = await target.perform(.sendKey(function13))

        XCTAssertEqual(result, .unsupported)
        XCTAssertTrue(sink.transitions.isEmpty)
    }

    func testMacRemoteIntentIsUnsupportedWithoutEmittingWindowsKeys() async {
        let sink = FakeWindowsKeySink()
        let target = NVDARemoteIntentTarget(keySink: sink)

        let result = await target.perform(.macRemote(.nextItem))

        XCTAssertEqual(result, .unsupported)
        XCTAssertTrue(sink.transitions.isEmpty)
    }
}

private struct KeyTransition: Equatable {
    let vk: UInt16
    let pressed: Bool

    init(_ vk: UInt16, _ pressed: Bool) {
        self.vk = vk
        self.pressed = pressed
    }
}

@MainActor
private final class FakeWindowsKeySink: RemoteWindowsKeySink {
    var isInputForwardingReady: Bool
    var activeProfileID: UUID?
    var transitions: [KeyTransition] = []

    init(isInputForwardingReady: Bool = true) {
        self.isInputForwardingReady = isInputForwardingReady
    }

    func sendKey(vk: UInt16, pressed: Bool) {
        transitions.append(KeyTransition(vk, pressed))
    }
}
