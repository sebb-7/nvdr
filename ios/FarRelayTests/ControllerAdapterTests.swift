import XCTest
@testable import FarRelay

@MainActor
final class ControllerAdapterTests: XCTestCase {
    func testSavedDpadUpCreatesTransitionsWithoutForwardKeyboard() async {
        let defaults = makeDefaults()
        let mappings = ControllerMappingSettings(defaults: defaults)
        mappings.setAction(.keyboard(.init(key: .up)), for: .dpadUp)
        mappings.saveDraft()
        let diagnostics = InputDiagnosticStore()
        diagnostics.isEnabled = true
        let sink = ControllerTestKeySink()
        let router = RemoteIntentRouter()
        router.register(NVDARemoteIntentTarget(keySink: sink))
        XCTAssertTrue(router.setActiveTarget(id: RemoteTargetID("nvda")))
        let adapter = DualSenseControllerAdapter(
            mappings: mappings,
            settings: AppSettings(),
            router: router,
            diagnostics: diagnostics
        )

        // This sink models a ready command channel while the local responder's
        // Forward Keyboard setting is off. Controller routing must still work.
        sink.forwardKeyboardEnabled = false
        adapter.receiveForTesting(input: .dpadUp, pressed: true, at: 1)
        adapter.receiveForTesting(input: .dpadUp, pressed: false, at: 2)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(sink.transitions, [.init(VK.up, true), .init(VK.up, false)])
        XCTAssertTrue(diagnostics.entries.contains { $0.source == .controller && $0.controllerInput == .dpadUp && $0.result.contains("Binding lookup: matched") })
        XCTAssertTrue(diagnostics.entries.contains { $0.source == .controller && $0.result.contains("RemoteIntent created") })
        XCTAssertTrue(diagnostics.entries.contains { $0.source == .controller && $0.result.contains("Capability routing: supported") })
    }

    func testDpadSnapshotNormalizationRoutesAllFourDirections() async {
        let defaults = makeDefaults()
        let mappings = ControllerMappingSettings(defaults: defaults)
        mappings.setAction(.keyboard(.init(key: .up)), for: .dpadUp)
        mappings.setAction(.keyboard(.init(key: .down)), for: .dpadDown)
        mappings.setAction(.keyboard(.init(key: .left)), for: .dpadLeft)
        mappings.setAction(.keyboard(.init(key: .right)), for: .dpadRight)
        mappings.saveDraft()

        let diagnostics = InputDiagnosticStore()
        diagnostics.isEnabled = true
        let sink = ControllerTestKeySink()
        let router = RemoteIntentRouter()
        router.register(NVDARemoteIntentTarget(keySink: sink))
        XCTAssertTrue(router.setActiveTarget(id: NVDARemoteIntentTarget.defaultID))
        let adapter = DualSenseControllerAdapter(
            mappings: mappings,
            settings: AppSettings(),
            router: router,
            diagnostics: diagnostics
        )

        adapter.receiveDpadForTesting(up: true, down: false, left: false, right: false, at: 1)
        adapter.receiveDpadForTesting(up: false, down: false, left: false, right: false, at: 2)
        adapter.receiveDpadForTesting(up: false, down: true, left: false, right: false, at: 3)
        adapter.receiveDpadForTesting(up: false, down: false, left: false, right: false, at: 4)
        adapter.receiveDpadForTesting(up: false, down: false, left: true, right: false, at: 5)
        adapter.receiveDpadForTesting(up: false, down: false, left: false, right: false, at: 6)
        adapter.receiveDpadForTesting(up: false, down: false, left: false, right: true, at: 7)
        adapter.receiveDpadForTesting(up: false, down: false, left: false, right: false, at: 8)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.up, true), .init(VK.up, false),
                .init(VK.down, true), .init(VK.down, false),
                .init(VK.left, true), .init(VK.left, false),
                .init(VK.right, true), .init(VK.right, false)
            ]
        )
        for input in [ControllerInput.dpadUp, .dpadDown, .dpadLeft, .dpadRight] {
            XCTAssertTrue(
                diagnostics.entries.contains {
                    $0.source == .controller &&
                    $0.controllerInput == input &&
                    $0.result.contains("Binding lookup: matched")
                }
            )
        }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "ControllerAdapterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}

private struct ControllerTransition: Equatable {
    let key: UInt16
    let pressed: Bool

    init(_ key: UInt16, _ pressed: Bool) {
        self.key = key
        self.pressed = pressed
    }
}

@MainActor
private final class ControllerTestKeySink: RemoteWindowsKeySink {
    var isInputForwardingReady = true
    var activeProfileID: UUID?
    var inputSessionID: UUID? = UUID()
    var lastInputForwardingResult: InputForwardingResult? = .accepted
    var forwardKeyboardEnabled = true
    var transitions: [ControllerTransition] = []

    func sendKey(vk: UInt16, pressed: Bool) {
        transitions.append(.init(vk, pressed))
    }
}
