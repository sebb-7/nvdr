import Foundation
import XCTest
@testable import FarRelay

@MainActor
final class QuickCommandModifierOnlyExecutionTests: XCTestCase {
    func testControlShiftExecutesAsBalancedModifierOnlyChord() async {
        let (adapter, sink, cleanup) = makeAdapter()
        defer { cleanup() }

        enterQuickCommandMode(adapter)
        adapter.updateQuickCommandBuffer("ctrl+shift")

        XCTAssertEqual(adapter.prepareQuickCommandForConfirmation(), "Control plus Shift")
        XCTAssertTrue(adapter.confirmQuickCommand())
        await adapter.waitForQuickCommandForTesting()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(key: VK.control, pressed: true),
                .init(key: VK.shift, pressed: true),
                .init(key: VK.shift, pressed: false),
                .init(key: VK.control, pressed: false),
            ]
        )
        XCTAssertTrue(sink.texts.isEmpty)
        XCTAssertFalse(adapter.isQuickCommandModeActive)
        XCTAssertFalse(adapter.isQuickNavigationActiveForTesting)
    }

    func testModifierOnlyStepReleasesBeforeFollowingTabStep() async {
        let (adapter, sink, cleanup) = makeAdapter()
        defer { cleanup() }

        enterQuickCommandMode(adapter)
        adapter.updateQuickCommandBuffer("ctrl+shift,tab")

        XCTAssertEqual(
            adapter.prepareQuickCommandForConfirmation(),
            "Control plus Shift. Then Tab"
        )
        XCTAssertTrue(adapter.confirmQuickCommand())
        await adapter.waitForQuickCommandForTesting()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(key: VK.control, pressed: true),
                .init(key: VK.shift, pressed: true),
                .init(key: VK.shift, pressed: false),
                .init(key: VK.control, pressed: false),
                .init(key: VK.tab, pressed: true),
                .init(key: VK.tab, pressed: false),
            ]
        )
        XCTAssertTrue(sink.texts.isEmpty)
    }

    private func enterQuickCommandMode(_ adapter: DualSenseControllerAdapter) {
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)
        XCTAssertTrue(adapter.isQuickCommandModeActive)
    }

    private func makeAdapter() -> (
        DualSenseControllerAdapter,
        ModifierOnlyTestKeySink,
        () -> Void
    ) {
        let suite = "QuickCommandModifierOnlyExecutionTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Unable to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suite)

        let mappings = ControllerMappingSettings(defaults: defaults)
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()

        let settings = AppSettings()
        let diagnostics = InputDiagnosticStore()
        let router = RemoteIntentRouter()
        let sink = ModifierOnlyTestKeySink()
        router.register(NVDARemoteIntentTarget(keySink: sink))
        XCTAssertTrue(router.setActiveTarget(id: NVDARemoteIntentTarget.defaultID))

        let adapter = DualSenseControllerAdapter(
            mappings: mappings,
            settings: settings,
            router: router,
            diagnostics: diagnostics,
            feedback: InteractionFeedback(settings: settings)
        )

        return (
            adapter,
            sink,
            { defaults.removePersistentDomain(forName: suite) }
        )
    }
}

private struct ModifierOnlyTransition: Equatable {
    let key: UInt16
    let pressed: Bool
}

@MainActor
private final class ModifierOnlyTestKeySink: RemoteWindowsKeySink {
    var isInputForwardingReady = true
    var activeProfileID: UUID?
    var inputSessionID: UUID? = UUID()
    var lastInputForwardingResult: InputForwardingResult? = .accepted

    private(set) var transitions: [ModifierOnlyTransition] = []
    private(set) var texts: [String] = []

    func sendKey(vk: UInt16, pressed: Bool) {
        transitions.append(.init(key: vk, pressed: pressed))
        lastInputForwardingResult = .accepted
    }

    func sendText(_ text: String) -> InputForwardingResult {
        texts.append(text)
        lastInputForwardingResult = .accepted
        return .accepted
    }
}
