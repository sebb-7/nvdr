import XCTest
@testable import FarRelay

@MainActor
final class LayerHeldStickyModifierRepeatTests: XCTestCase {
    func testLayerOwnedOneModifierRetapsWithoutReleasingUntilLayerRelease() async {
        await assertLayerOwnedRepeatTap(
            modifiers: [.alt],
            expectedModifierDowns: [VK.menu],
            expectedModifierReleases: [VK.menu]
        )
    }

    func testLayerOwnedTwoModifiersRetapWithoutReleasingUntilLayerRelease() async {
        await assertLayerOwnedRepeatTap(
            modifiers: [.alt, .shift],
            expectedModifierDowns: [VK.shift, VK.menu],
            expectedModifierReleases: [VK.menu, VK.shift]
        )
    }

    func testLayerOwnedThreeModifiersRetapWithoutReleasingUntilLayerRelease() async {
        await assertLayerOwnedRepeatTap(
            modifiers: [.alt, .shift, .control],
            expectedModifierDowns: [VK.shift, VK.control, VK.menu],
            expectedModifierReleases: [VK.menu, VK.control, VK.shift]
        )
    }

    private func assertLayerOwnedRepeatTap(
        modifiers: Set<ControllerKeyboardModifier>,
        expectedModifierDowns: [UInt16],
        expectedModifierReleases: [UInt16]
    ) async {
        let suiteName = "LayerHeldStickyModifierRepeatTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mappings = ControllerMappingSettings(defaults: defaults)
        mappings.setAction(.layer(.init()), for: .options)
        mappings.setAction(
            .stickyModifier(.init(modifiers: modifiers, tapKey: .tab)),
            for: .leftShoulder,
            layerID: ControllerLayerDefinition.extendedID
        )
        mappings.saveDraft()

        let diagnostics = InputDiagnosticStore()
        diagnostics.isEnabled = true
        let sink = LayerHeldRepeatTestKeySink()
        let router = RemoteIntentRouter()
        router.register(NVDARemoteIntentTarget(keySink: sink))
        XCTAssertTrue(router.setActiveTarget(id: NVDARemoteIntentTarget.defaultID))
        let settings = AppSettings()
        let adapter = DualSenseControllerAdapter(
            mappings: mappings,
            settings: settings,
            router: router,
            diagnostics: diagnostics,
            feedback: InteractionFeedback(settings: settings)
        )

        adapter.receiveForTesting(input: .options, pressed: true, at: 1)

        for index in 0..<3 {
            let time = 1.1 + (Double(index) * 0.2)
            adapter.receiveForTesting(input: .leftShoulder, pressed: true, at: time)
            adapter.receiveForTesting(input: .leftShoulder, pressed: false, at: time + 0.1)
            await settle()
        }

        var expected = expectedModifierDowns.map { LayerHeldRepeatTransition($0, true) }
        for _ in 0..<3 {
            expected.append(.init(VK.tab, true))
            expected.append(.init(VK.tab, false))
        }
        XCTAssertEqual(sink.transitions, expected)
        XCTAssertFalse(
            sink.transitions.contains {
                expectedModifierReleases.contains($0.key) && !$0.pressed
            },
            "Layer-owned modifiers must stay down across repeat taps."
        )

        adapter.receiveForTesting(input: .options, pressed: false, at: 2)
        await settle()

        expected.append(contentsOf: expectedModifierReleases.map {
            LayerHeldRepeatTransition($0, false)
        })
        XCTAssertEqual(sink.transitions, expected)
        XCTAssertEqual(adapter.layerStateForTesting, .base)
    }

    private func settle() async {
        await Task.yield()
        await Task.yield()
        await Task.yield()
        await Task.yield()
    }
}

private struct LayerHeldRepeatTransition: Equatable {
    let key: UInt16
    let pressed: Bool

    init(_ key: UInt16, _ pressed: Bool) {
        self.key = key
        self.pressed = pressed
    }
}

@MainActor
private final class LayerHeldRepeatTestKeySink: RemoteWindowsKeySink {
    var isInputForwardingReady = true
    var activeProfileID: UUID?
    var inputSessionID: UUID? = UUID()
    var lastInputForwardingResult: InputForwardingResult? = .accepted
    private(set) var transitions: [LayerHeldRepeatTransition] = []

    func sendKey(vk: UInt16, pressed: Bool) {
        transitions.append(.init(vk, pressed))
    }
}
