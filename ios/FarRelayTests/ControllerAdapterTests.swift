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
            diagnostics: diagnostics,
            feedback: InteractionFeedback(settings: AppSettings())
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
            diagnostics: diagnostics,
            feedback: InteractionFeedback(settings: AppSettings())
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

    func testLayerControlRemainsReachableWhileOneShotLayerIsActive() async {
        let (_, adapter, sink, feedback, _) = makeAdapter()
        adapter.receiveForTesting(input: .options, pressed: true, at: 1)
        adapter.receiveForTesting(input: .options, pressed: false, at: 1.1)
        XCTAssertEqual(adapter.layerStateForTesting, .oneShot("extended"))

        adapter.receiveForTesting(input: .options, pressed: true, at: 1.2)
        adapter.receiveForTesting(input: .options, pressed: false, at: 1.3)
        XCTAssertEqual(adapter.layerStateForTesting, .locked("extended"))
        XCTAssertEqual(feedback.lastRequest?.kind, .success)
        XCTAssertTrue(sink.transitions.isEmpty)
    }

    func testLayerControlRemainsReachableWhileLayerIsLocked() {
        let (_, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .options, pressed: true, at: 1)
        adapter.receiveForTesting(input: .options, pressed: false, at: 1.1)
        adapter.receiveForTesting(input: .options, pressed: true, at: 1.2)
        adapter.receiveForTesting(input: .options, pressed: false, at: 1.3)
        XCTAssertEqual(adapter.layerStateForTesting, .locked("extended"))

        adapter.receiveForTesting(input: .options, pressed: true, at: 1.4)
        adapter.receiveForTesting(input: .options, pressed: false, at: 1.5)
        XCTAssertEqual(adapter.layerStateForTesting, .base)
        XCTAssertTrue(sink.transitions.isEmpty)
    }

    func testOneShotLayerIsConsumedOnlyByResolvedLayerAction() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .options, pressed: true, at: 1)
        adapter.receiveForTesting(input: .options, pressed: false, at: 1.1)
        adapter.receiveForTesting(input: .leftStickUp, pressed: true, at: 1.2)
        adapter.receiveForTesting(input: .leftStickUp, pressed: false, at: 1.3)
        XCTAssertEqual(adapter.layerStateForTesting, .oneShot("extended"))

        adapter.receiveForTesting(input: .dpadUp, pressed: true, at: 1.4)
        await settle()
        adapter.receiveForTesting(input: .dpadUp, pressed: false, at: 1.5)
        await settle()
        XCTAssertEqual(adapter.layerStateForTesting, .base)
        XCTAssertEqual(sink.transitions, [.init(VK.prior, true), .init(VK.prior, false)])
    }

    func testActionReleaseUsesOriginalResolvedActionAfterLayerChanges() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .options, pressed: true, at: 1)
        adapter.receiveForTesting(input: .dpadUp, pressed: true, at: 1.1)
        await settle()
        adapter.receiveForTesting(input: .options, pressed: false, at: 1.2)
        adapter.receiveForTesting(input: .dpadUp, pressed: false, at: 1.3)
        await settle()
        XCTAssertEqual(sink.transitions, [.init(VK.prior, true), .init(VK.prior, false)])
    }

    func testControllerStopClearsAllTransientModesAndReleasesHeldKey() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .create, pressed: true, at: 1)
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)
        adapter.receiveForTesting(input: .touchpadPress, pressed: true, at: 1.1)
        XCTAssertTrue(adapter.isTextModeActive)
        XCTAssertFalse(adapter.isQuickNavigationActiveForTesting)
        adapter.exitTextMode()
        adapter.receiveForTesting(input: .dpadUp, pressed: true, at: 1.2)
        await settle()
        adapter.stop()
        await settle()
        XCTAssertFalse(adapter.isTextModeActive)
        XCTAssertFalse(adapter.isQuickNavigationActiveForTesting)
        XCTAssertEqual(adapter.layerStateForTesting, .base)
        XCTAssertEqual(sink.transitions, [.init(VK.up, true), .init(VK.up, false)])
    }

    func testProfileSaveReleasesCurrentlyActiveActionBeforeApplyingMappings() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .dpadUp, pressed: true, at: 1)
        await settle()
        mappings.setAction(.keyboard(.init(key: .tab)), for: .dpadUp)
        mappings.saveDraft()
        await settle()
        XCTAssertEqual(sink.transitions, [.init(VK.up, true), .init(VK.up, false)])
    }

    func testQuickNavigationUsesRightStickAndQuickBarConsumesCrossLocally() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .create, pressed: true, at: 1)

        // Quick Bar starts on Show Desktop. Cross executes Windows+D; it must
        // not send Enter to the remote computer while this section is active.
        adapter.receiveForTesting(input: .cross, pressed: true, at: 1.1)
        adapter.receiveForTesting(input: .cross, pressed: false, at: 1.2)

        // Right selects Headings. Down moves to the next heading, then the
        // same Cross button becomes remote Enter for the selected element.
        adapter.receiveForTesting(input: .rightStickRight, pressed: true, at: 1.3)
        adapter.receiveForTesting(input: .rightStickRight, pressed: false, at: 1.4)
        adapter.receiveForTesting(input: .rightStickDown, pressed: true, at: 1.5)
        adapter.receiveForTesting(input: .rightStickDown, pressed: false, at: 1.6)
        adapter.receiveForTesting(input: .cross, pressed: true, at: 1.7)
        adapter.receiveForTesting(input: .cross, pressed: false, at: 1.8)
        await settle()

        adapter.receiveForTesting(input: .circle, pressed: true, at: 1.9)
        XCTAssertFalse(adapter.isQuickNavigationActiveForTesting)
        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.lwin, true), .init(0x44, true), .init(0x44, false), .init(VK.lwin, false),
                .init(0x48, true), .init(0x48, false),
                .init(VK.return, true), .init(VK.return, false)
            ]
        )
    }

    func testUnsupportedLocalCharacterCannotDeleteRemoteMirroredCharacter() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .touchpadPress, pressed: true, at: 1)
        _ = adapter.applyTextModeEditorValue("aé")
        await adapter.waitForTextOperationsForTesting()
        _ = adapter.applyTextModeEditorValue("a")
        await adapter.waitForTextOperationsForTesting()
        XCTAssertEqual(adapter.textModeBuffer, "a")
        XCTAssertEqual(sink.transitions, [.init(0x41, true), .init(0x41, false)])
    }

    func testRemoteBackspaceDoesNotCauseLaterDuplicateLocalDeletion() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .touchpadPress, pressed: true, at: 1)
        _ = adapter.applyTextModeEditorValue("ab")
        await adapter.waitForTextOperationsForTesting()
        adapter.receiveForTesting(input: .rightStickPress, pressed: true, at: 1.1)
        await adapter.waitForTextOperationsForTesting()
        _ = adapter.applyTextModeEditorValue("a")
        await adapter.waitForTextOperationsForTesting()
        XCTAssertEqual(adapter.textModeBuffer, "a")
        XCTAssertEqual(sink.transitions.filter { $0.key == VK.back && $0.pressed }, [.init(VK.back, true)])
    }

    func testTextOperationsRemainInSubmissionOrderAndDiagnosticsContainNoText() async {
        let (_, adapter, sink, _, diagnostics) = makeAdapter()
        adapter.receiveForTesting(input: .touchpadPress, pressed: true, at: 1)
        _ = adapter.applyTextModeEditorValue("abc")
        await adapter.waitForTextOperationsForTesting()
        XCTAssertEqual(sink.transitions.map(\.key), [0x41, 0x41, 0x42, 0x42, 0x43, 0x43])
        _ = adapter.applyTextModeEditorValue("SECRET_SENTINEL_123")
        await adapter.waitForTextOperationsForTesting()
        XCTAssertFalse(diagnostics.entries.contains { $0.result.contains("SECRET_SENTINEL_123") })
    }

    func testNativeBSIDeleteWithEmptyLocalBufferBackspacesPreexistingRemoteText() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .touchpadPress, pressed: true, at: 1)
        XCTAssertEqual(adapter.textModeBuffer, "")

        adapter.handleTextModeDeleteBackwardWhenLocalBufferEmpty()
        await adapter.waitForTextOperationsForTesting()

        XCTAssertEqual(adapter.textModeBuffer, "")
        XCTAssertEqual(sink.transitions, [.init(VK.back, true), .init(VK.back, false)])
    }

    func testNativeBSIDeleteEmptyHookFiresWithoutLocalTextMutation() {
        let textView = RemoteTextModeTextView()
        var emptyDeleteCount = 0
        textView.onDeleteBackwardWhenEmpty = { emptyDeleteCount += 1 }
        textView.text = ""

        textView.deleteBackward()

        XCTAssertEqual(emptyDeleteCount, 1)
        XCTAssertEqual(textView.text, "")
    }

    private func makeDefaults() -> UserDefaults {
        let name = "ControllerAdapterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeAdapter() -> (ControllerMappingSettings, DualSenseControllerAdapter, ControllerTestKeySink, InteractionFeedback, InputDiagnosticStore) {
        let defaults = makeDefaults()
        let mappings = ControllerMappingSettings(defaults: defaults)
        let diagnostics = InputDiagnosticStore()
        diagnostics.isEnabled = true
        let sink = ControllerTestKeySink()
        let router = RemoteIntentRouter()
        router.register(NVDARemoteIntentTarget(keySink: sink))
        XCTAssertTrue(router.setActiveTarget(id: NVDARemoteIntentTarget.defaultID))
        let settings = AppSettings()
        let feedback = InteractionFeedback(settings: settings)
        return (mappings, DualSenseControllerAdapter(mappings: mappings, settings: settings, router: router, diagnostics: diagnostics, feedback: feedback), sink, feedback, diagnostics)
    }

    private func settle() async {
        await Task.yield()
        await Task.yield()
        await Task.yield()
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
