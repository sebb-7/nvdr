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

    func testAccessibilityIntentUsesDocumentedFocusShimWithoutRawTextFallback() async {
        let sink = FakeWindowsKeySink()
        let target = NVDARemoteIntentTarget(keySink: sink)

        let result = await target.perform(.accessibilityActivate)
        XCTAssertEqual(result, .performed)
        XCTAssertEqual(sink.transitions, [.init(VK.return, true), .init(VK.return, false)])
    }

    func testResolvedTextIsPassedWithoutVirtualKeyTranslation() async {
        let sink = FakeWindowsKeySink()
        let target = NVDARemoteIntentTarget(keySink: sink)

        let result = await target.perform(.sendText("/ ? [ ] { } \\ | ; : ' \" , < . > - _ = +"))

        XCTAssertEqual(result, .performed)
        XCTAssertEqual(sink.texts, ["/ ? [ ] { } \\ | ; : ' \" , < . > - _ = +"])
        XCTAssertTrue(sink.transitions.isEmpty)
    }

    func testRejectedResolvedTextIsNotReportedAsPerformed() async {
        let sink = FakeWindowsKeySink()
        sink.lastInputForwardingResult = .rejected("transmission queue is full")
        let target = NVDARemoteIntentTarget(keySink: sink)

        let result = await target.perform(.sendText("á"))

        XCTAssertEqual(result, .failed("NVDA transport rejected the text: transmission queue is full"))
        XCTAssertEqual(sink.texts, ["á"])
        XCTAssertTrue(sink.transitions.isEmpty)
    }

    func testStatefulChordBalancesModifierAndKeyOnRelease() async {
        let sink = FakeWindowsKeySink()
        let target = NVDARemoteIntentTarget(keySink: sink)
        let chord = RemoteChord(modifiers: [.alt, .shift], key: .tab)

        let press = await target.perform(.sendChordTransition(chord, pressed: true))
        let repeatResult = await target.perform(.repeatChord(chord))
        let release = await target.perform(.sendChordTransition(chord, pressed: false))
        XCTAssertEqual(press, .performed)
        XCTAssertEqual(repeatResult, .performed)
        XCTAssertEqual(release, .performed)

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.menu, true), .init(VK.shift, true), .init(VK.tab, true),
                .init(VK.tab, true), .init(VK.tab, false), .init(VK.shift, false), .init(VK.menu, false)
            ]
        )
    }

    func testOverlappingChordsKeepSharedModifierHeldUntilLastRelease() async {
        let sink = FakeWindowsKeySink()
        let target = NVDARemoteIntentTarget(keySink: sink)
        let tab = RemoteChord(modifiers: [.alt], key: .tab)
        guard let letterF = RemoteKey.letter("f") else { return XCTFail("Expected F") }
        let f = RemoteChord(modifiers: [.alt], key: letterF)

        _ = await target.perform(.sendChordTransition(tab, pressed: true))
        _ = await target.perform(.sendChordTransition(f, pressed: true))
        _ = await target.perform(.sendChordTransition(tab, pressed: false))
        _ = await target.perform(.sendChordTransition(f, pressed: false))

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.menu, true), .init(VK.tab, true), .init(0x46, true),
                .init(VK.tab, false), .init(0x46, false), .init(VK.menu, false)
            ]
        )
    }

    func testNewInputChannelDoesNotInheritHeldControllerKey() async {
        let sink = FakeWindowsKeySink()
        let target = NVDARemoteIntentTarget(keySink: sink)
        let key = RemoteKey.tab

        _ = await target.perform(.sendKeyTransition(key, pressed: true))
        sink.inputSessionID = UUID()
        _ = await target.perform(.sendKeyTransition(key, pressed: true))

        XCTAssertEqual(sink.transitions, [.init(VK.tab, true), .init(VK.tab, true)])
    }

    func testOldSessionReleaseIsDiscardedInsteadOfTouchingNewChannel() async {
        let sink = FakeWindowsKeySink()
        let target = NVDARemoteIntentTarget(keySink: sink)

        _ = await target.perform(.sendKeyTransition(.tab, pressed: true))
        sink.inputSessionID = UUID()
        _ = await target.perform(.sendKeyTransition(.tab, pressed: false))

        XCTAssertEqual(sink.transitions, [.init(VK.tab, true)])
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
    var inputSessionID: UUID?
    var lastInputForwardingResult: InputForwardingResult? = .accepted
    var transitions: [KeyTransition] = []
    var texts: [String] = []

    init(isInputForwardingReady: Bool = true) {
        self.isInputForwardingReady = isInputForwardingReady
    }

    func sendKey(vk: UInt16, pressed: Bool) {
        transitions.append(KeyTransition(vk, pressed))
    }

    func sendText(_ text: String) -> InputForwardingResult {
        texts.append(text)
        return lastInputForwardingResult ?? .accepted
    }
}
