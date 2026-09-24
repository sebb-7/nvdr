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

    func testOneShotLayerIsConsumedBySuccessfulLocalAction() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .options, pressed: true, at: 1)
        adapter.receiveForTesting(input: .options, pressed: false, at: 1.1)
        XCTAssertEqual(adapter.layerStateForTesting, .oneShot("extended"))

        // Extended + Cross defaults to Repeat Last Quick Bar Action. Even
        // with no repeat history, the local command is handled and consumes
        // the one-shot layer instead of leaving it armed.
        adapter.receiveForTesting(input: .cross, pressed: true, at: 1.2)
        adapter.receiveForTesting(input: .cross, pressed: false, at: 1.3)
        await settle()

        XCTAssertEqual(adapter.layerStateForTesting, .base)
        XCTAssertTrue(sink.transitions.isEmpty)
    }

    func testLayerReturnToBaseUsesNeutralSelectionFeedback() async {
        let (_, adapter, _, feedback, _) = makeAdapter()
        adapter.receiveForTesting(input: .options, pressed: true, at: 1)
        adapter.receiveForTesting(input: .dpadUp, pressed: true, at: 1.1)
        await settle()
        adapter.receiveForTesting(input: .dpadUp, pressed: false, at: 1.2)
        await settle()
        adapter.receiveForTesting(input: .options, pressed: false, at: 1.3)

        XCTAssertEqual(adapter.layerStateForTesting, .base)
        XCTAssertEqual(feedback.lastRequest?.kind, .selectionAccepted)
        XCTAssertNotEqual(feedback.lastRequest?.kind, .warning)
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
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)
        adapter.receiveForTesting(input: .touchpadPress, pressed: true, at: 1.1)
        XCTAssertTrue(adapter.isTextModeActive)
        XCTAssertFalse(adapter.isQuickNavigationActiveForTesting)
        adapter.exitTextMode()
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)
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

    func testBaseStickyAltStillTogglesForBackwardCompatibility() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(.stickyModifier(.init(modifier: .alt)), for: .triangle)
        mappings.saveDraft()

        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)
        adapter.receiveForTesting(input: .leftShoulder, pressed: true, at: 1.2)
        adapter.receiveForTesting(input: .leftShoulder, pressed: false, at: 1.3)
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1.4)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.5)
        await settle()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.menu, true),
                .init(VK.tab, true), .init(VK.tab, false),
                .init(VK.menu, false)
            ]
        )
    }

    func testHoldModifierCanHoldMultipleModifiersAndTapOneKeyOnce() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(
            .stickyModifier(.init(modifiers: [.alt, .shift], tapKey: .tab)),
            for: .triangle
        )
        mappings.saveDraft()

        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)
        await settle()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.shift, true),
                .init(VK.menu, true),
                .init(VK.tab, true), .init(VK.tab, false)
            ]
        )

        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1.2)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.3)
        await settle()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.shift, true),
                .init(VK.menu, true),
                .init(VK.tab, true), .init(VK.tab, false),
                .init(VK.menu, false),
                .init(VK.shift, false)
            ]
        )
    }

    func testLayerScopedShiftUsesBaseDpadAndReleasesWithLayerButton() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(
            .stickyModifier(.init(modifier: .shift)),
            for: .circle,
            layerID: ControllerLayerDefinition.extendedID
        )
        mappings.saveDraft()

        adapter.receiveForTesting(input: .options, pressed: true, at: 1)
        adapter.receiveForTesting(input: .circle, pressed: true, at: 1.1)
        adapter.receiveForTesting(input: .circle, pressed: false, at: 1.2)

        // Extended D-pad Up is Page Up, but once Shift is armed by the held
        // layer the D-pad must temporarily resolve through Base: Up Arrow.
        adapter.receiveForTesting(input: .dpadUp, pressed: true, at: 1.3)
        adapter.receiveForTesting(input: .dpadUp, pressed: false, at: 1.4)
        adapter.receiveForTesting(input: .options, pressed: false, at: 1.5)
        await settle()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.shift, true),
                .init(VK.up, true), .init(VK.up, false),
                .init(VK.shift, false)
            ]
        )
        XCTAssertEqual(adapter.layerStateForTesting, .base)
    }

    func testLayerScopedAltKeepsAltDownAcrossRepeatedBaseTabUntilLayerRelease() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(
            .stickyModifier(.init(modifier: .alt)),
            for: .circle,
            layerID: ControllerLayerDefinition.extendedID
        )
        mappings.saveDraft()

        adapter.receiveForTesting(input: .options, pressed: true, at: 1)
        adapter.receiveForTesting(input: .circle, pressed: true, at: 1.1)
        adapter.receiveForTesting(input: .circle, pressed: false, at: 1.2)
        adapter.receiveForTesting(input: .leftShoulder, pressed: true, at: 1.3)
        adapter.receiveForTesting(input: .leftShoulder, pressed: false, at: 1.4)
        adapter.receiveForTesting(input: .leftShoulder, pressed: true, at: 1.5)
        adapter.receiveForTesting(input: .leftShoulder, pressed: false, at: 1.6)
        adapter.receiveForTesting(input: .options, pressed: false, at: 1.7)
        await settle()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.menu, true),
                .init(VK.tab, true), .init(VK.tab, false),
                .init(VK.tab, true), .init(VK.tab, false),
                .init(VK.menu, false)
            ]
        )
    }

    func testLayerScopedModifierReleasesBeforeProfileSwitch() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(
            .stickyModifier(.init(modifier: .alt)),
            for: .circle,
            layerID: ControllerLayerDefinition.extendedID
        )
        mappings.saveDraft()
        _ = mappings.createProfile(name: "Hearthstone")

        adapter.receiveForTesting(input: .options, pressed: true, at: 1)
        adapter.receiveForTesting(input: .circle, pressed: true, at: 1.1)
        adapter.receiveForTesting(input: .circle, pressed: false, at: 1.2)
        mappings.activateNextProfile()
        await settle()

        XCTAssertEqual(sink.transitions, [.init(VK.menu, true), .init(VK.menu, false)])
        XCTAssertEqual(mappings.activeProfile.name, "Hearthstone")
        XCTAssertEqual(adapter.layerStateForTesting, .base)
    }

    func testLayerScopedModifierReleasesOnInactiveContext() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(
            .stickyModifier(.init(modifier: .alt)),
            for: .circle,
            layerID: ControllerLayerDefinition.extendedID
        )
        mappings.saveDraft()

        adapter.receiveForTesting(input: .options, pressed: true, at: 1)
        adapter.receiveForTesting(input: .circle, pressed: true, at: 1.1)
        adapter.receiveForTesting(input: .circle, pressed: false, at: 1.2)
        adapter.suspendInputForInactiveContext()
        await settle()

        XCTAssertEqual(sink.transitions, [.init(VK.menu, true), .init(VK.menu, false)])
        XCTAssertEqual(adapter.layerStateForTesting, .base)
    }

    func testLayerScopedMultipleModifiersKeepBaseMappingsUntilLayerRelease() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(
            .stickyModifier(.init(modifier: .shift)),
            for: .circle,
            layerID: ControllerLayerDefinition.extendedID
        )
        mappings.setAction(
            .stickyModifier(.init(modifier: .control)),
            for: .square,
            layerID: ControllerLayerDefinition.extendedID
        )
        mappings.saveDraft()

        adapter.receiveForTesting(input: .options, pressed: true, at: 1)
        adapter.receiveForTesting(input: .circle, pressed: true, at: 1.1)
        adapter.receiveForTesting(input: .circle, pressed: false, at: 1.2)
        adapter.receiveForTesting(input: .square, pressed: true, at: 1.3)
        adapter.receiveForTesting(input: .square, pressed: false, at: 1.4)
        adapter.receiveForTesting(input: .dpadRight, pressed: true, at: 1.5)
        adapter.receiveForTesting(input: .dpadRight, pressed: false, at: 1.6)
        adapter.receiveForTesting(input: .options, pressed: false, at: 1.7)
        await settle()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.shift, true),
                .init(VK.control, true),
                .init(VK.right, true), .init(VK.right, false),
                .init(VK.control, false),
                .init(VK.shift, false)
            ]
        )
        XCTAssertEqual(adapter.layerStateForTesting, .base)
    }

    func testLayerScopedModifierReleasesBeforeMappingSave() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(
            .stickyModifier(.init(modifier: .alt)),
            for: .circle,
            layerID: ControllerLayerDefinition.extendedID
        )
        mappings.saveDraft()

        adapter.receiveForTesting(input: .options, pressed: true, at: 1)
        adapter.receiveForTesting(input: .circle, pressed: true, at: 1.1)
        adapter.receiveForTesting(input: .circle, pressed: false, at: 1.2)
        mappings.setAction(.keyboard(.init(key: .f8)), for: .triangle)
        mappings.saveDraft()
        await settle()

        XCTAssertEqual(sink.transitions, [.init(VK.menu, true), .init(VK.menu, false)])
        XCTAssertEqual(adapter.layerStateForTesting, .base)
    }

    func testLayerScopedModifierReleasesOnAdapterStop() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(
            .stickyModifier(.init(modifier: .shift)),
            for: .circle,
            layerID: ControllerLayerDefinition.extendedID
        )
        mappings.saveDraft()

        adapter.receiveForTesting(input: .options, pressed: true, at: 1)
        adapter.receiveForTesting(input: .circle, pressed: true, at: 1.1)
        adapter.receiveForTesting(input: .circle, pressed: false, at: 1.2)
        adapter.stop()
        await settle()

        XCTAssertEqual(sink.transitions, [.init(VK.shift, true), .init(VK.shift, false)])
        XCTAssertEqual(adapter.layerStateForTesting, .base)
    }

    func testQuickNavigationUsesTouchpadRotorAndRightStickMovement() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        // This test exercises the local Quick Navigation exit. A mapped
        // remote Escape intentionally preempts that local behavior.
        mappings.setAction(nil, for: .circle)
        mappings.saveDraft()
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)

        // Quick Bar starts on Show Desktop. Cross executes Windows+D; it must
        // not send Enter to the remote computer while this section is active.
        adapter.receiveForTesting(input: .cross, pressed: true, at: 1.1)
        adapter.receiveForTesting(input: .cross, pressed: false, at: 1.2)

        // Quick Bar -> Profiles -> Controller Mapping -> Editing -> Headings
        // takes four horizontal swipes. Right-stick Down then moves to the next
        // heading and Cross becomes Enter.
        adapter.beginTouchpadSwipeForTesting(x: -0.5)
        adapter.moveTouchpadForTesting(x: 0.1)
        adapter.endTouchpadSwipeForTesting()
        adapter.beginTouchpadSwipeForTesting(x: -0.5)
        adapter.moveTouchpadForTesting(x: 0.1)
        adapter.endTouchpadSwipeForTesting()
        adapter.beginTouchpadSwipeForTesting(x: -0.5)
        adapter.moveTouchpadForTesting(x: 0.1)
        adapter.endTouchpadSwipeForTesting()
        adapter.beginTouchpadSwipeForTesting(x: -0.5)
        adapter.moveTouchpadForTesting(x: 0.1)
        adapter.endTouchpadSwipeForTesting()
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

    func testMappedRemoteEscapePreemptsQuickNavigationAndRoutesEveryPressExactlyOnce() async {
        let (mappings, adapter, sink, _, diagnostics) = makeAdapter()
        mappings.setAction(.keyboard(.init(key: .escape)), for: .circle)
        mappings.setAction(.keyboard(.init(key: .tab)), for: .triangle)
        mappings.saveDraft()
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)

        adapter.receiveForTesting(input: .circle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .circle, pressed: false, at: 1.1)
        adapter.receiveForTesting(input: .circle, pressed: true, at: 1.2)
        adapter.receiveForTesting(input: .circle, pressed: false, at: 1.3)
        await settle()

        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)
        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.escape, true), .init(VK.escape, false),
                .init(VK.escape, true), .init(VK.escape, false)
            ]
        )
        XCTAssertEqual(
            diagnostics.entries.filter { $0.result.contains("Mapped remote Escape preempted") }.count,
            2
        )

        // A non-Escape mapping continues to use its normal remote route.
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1.4)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.5)
        await settle()
        XCTAssertEqual(Array(sink.transitions.suffix(2)), [.init(VK.tab, true), .init(VK.tab, false)])
    }

    func testOneFingerTouchpadSwipeMovesExactlyOneRotorSectionPerContact() async {
        let (_, adapter, sink, _, _) = makeAdapter()

        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .quickBar)

        adapter.beginTouchpadSwipeForTesting(x: -0.6)
        adapter.moveTouchpadForTesting(x: -0.4)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .quickBar)

        adapter.moveTouchpadForTesting(x: 0.0)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .profiles)

        // Continued movement or reversal from the same finger cannot rotate twice.
        adapter.moveTouchpadForTesting(x: 0.8)
        adapter.moveTouchpadForTesting(x: -0.8)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .profiles)
        adapter.endTouchpadSwipeForTesting()

        // After lift, a new finger contact can rotate in the opposite direction.
        adapter.moveTouchpadForTesting(x: -0.8)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .profiles)
        adapter.beginTouchpadSwipeForTesting(x: 0.6)
        adapter.moveTouchpadForTesting(x: 0.0)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .quickBar)
        adapter.endTouchpadSwipeForTesting()

        XCTAssertTrue(sink.transitions.isEmpty)
    }

    func testTouchpadMovementRecoversWhenDownCallbackWasMissed() {
        let (_, adapter, sink, _, diagnostics) = makeAdapter()

        adapter.receiveTouchpadContactForTesting(.moving, x: -0.6)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .quickBar)

        adapter.receiveTouchpadContactForTesting(.moving, x: 0.0)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .profiles)

        // One contact still consumes only one rotor step.
        adapter.receiveTouchpadContactForTesting(.moving, x: 0.8)
        adapter.receiveTouchpadContactForTesting(.moving, x: -0.8)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .profiles)

        adapter.receiveTouchpadContactForTesting(.up, x: -0.8)
        adapter.receiveTouchpadContactForTesting(.moving, x: 0.6)
        adapter.receiveTouchpadContactForTesting(.moving, x: 0.0)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .quickBar)

        XCTAssertTrue(sink.transitions.isEmpty)
        XCTAssertTrue(
            diagnostics.entries.contains {
                $0.result == "Touchpad: recovered contact from movement"
            }
        )
    }

    func testTouchpadDoesNotRotateWhileActionLayerOwnsInput() {
        let (_, adapter, sink, _, _) = makeAdapter()

        adapter.receiveForTesting(input: .options, pressed: true, at: 1)
        adapter.receiveTouchpadContactForTesting(.down, x: -0.6)
        adapter.receiveTouchpadContactForTesting(.moving, x: 0.0)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .quickBar)

        adapter.receiveForTesting(input: .options, pressed: false, at: 1.1)

        // Releasing the layer does not revive the same finger contact.
        adapter.receiveTouchpadContactForTesting(.moving, x: 0.8)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .quickBar)
        adapter.receiveTouchpadContactForTesting(.up, x: 0.8)

        // Releasing a tapped layer arms one-shot Extended. Consume that local
        // one-shot before expecting Quick Navigation to own input again.
        adapter.receiveForTesting(input: .cross, pressed: true, at: 1.2)
        adapter.receiveForTesting(input: .cross, pressed: false, at: 1.3)
        XCTAssertEqual(adapter.layerStateForTesting, .base)

        adapter.receiveTouchpadContactForTesting(.down, x: -0.6)
        adapter.receiveTouchpadContactForTesting(.moving, x: 0.0)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .profiles)
        XCTAssertTrue(sink.transitions.isEmpty)
    }

    func testTextModeClearsInFlightTouchpadContactBeforeQuickNavigationReturns() {
        let (_, adapter, _, _, _) = makeAdapter()

        adapter.receiveTouchpadContactForTesting(.down, x: -0.6)
        adapter.receiveForTesting(input: .touchpadPress, pressed: true, at: 1)
        adapter.receiveForTesting(input: .touchpadPress, pressed: false, at: 1.1)
        XCTAssertTrue(adapter.isTextModeActive)

        adapter.receiveForTesting(input: .touchpadPress, pressed: true, at: 1.2)
        adapter.receiveForTesting(input: .touchpadPress, pressed: false, at: 1.3)
        XCTAssertFalse(adapter.isTextModeActive)
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)

        // Movement from the old finger contact must not rotate after mode exit.
        adapter.receiveTouchpadContactForTesting(.moving, x: 0.0)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .quickBar)

        adapter.receiveTouchpadContactForTesting(.moving, x: 0.6)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .profiles)
    }

    func testQuickCommandModeClearsInFlightTouchpadContact() {
        let (mappings, adapter, _, _, _) = makeAdapter()
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()

        adapter.receiveTouchpadContactForTesting(.down, x: -0.6)
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)
        XCTAssertTrue(adapter.isQuickCommandModeActive)

        adapter.exitQuickCommandMode()
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)

        adapter.receiveTouchpadContactForTesting(.moving, x: 0.0)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .quickBar)

        adapter.receiveTouchpadContactForTesting(.moving, x: 0.6)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .profiles)
    }

    func testQuickCommandMappedKeyTogglesModeOffWithoutSendingRemoteInput() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()

        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)
        XCTAssertTrue(adapter.isQuickCommandModeActive)
        XCTAssertFalse(adapter.isQuickNavigationActiveForTesting)

        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1.2)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.3)
        await settle()

        XCTAssertFalse(adapter.isQuickCommandModeActive)
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)
        XCTAssertTrue(sink.transitions.isEmpty)
    }

    func testQuickNavigationExitClearsInFlightTouchpadContact() {
        let (mappings, adapter, _, _, _) = makeAdapter()
        mappings.setAction(nil, for: .circle)
        mappings.saveDraft()

        adapter.receiveTouchpadContactForTesting(.down, x: -0.6)
        adapter.receiveForTesting(input: .circle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .circle, pressed: false, at: 1.1)
        XCTAssertFalse(adapter.isQuickNavigationActiveForTesting)

        adapter.receiveForTesting(input: .create, pressed: true, at: 1.2)
        adapter.receiveForTesting(input: .create, pressed: false, at: 1.3)
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)

        adapter.receiveTouchpadContactForTesting(.moving, x: 0.0)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .quickBar)
        adapter.receiveTouchpadContactForTesting(.moving, x: 0.6)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .profiles)
    }

    func testTouchpadDiagnosticsNeverContainRawCoordinates() {
        let (_, adapter, _, _, diagnostics) = makeAdapter()

        adapter.receiveTouchpadContactForTesting(.down, x: -0.612345)
        adapter.receiveTouchpadContactForTesting(.moving, x: 0.123456)

        XCTAssertFalse(
            diagnostics.entries.contains {
                $0.result.contains("-0.612345") || $0.result.contains("0.123456")
            }
        )
        XCTAssertTrue(
            diagnostics.entries.contains {
                $0.result.contains("Touchpad: rotor threshold crossed")
            }
        )
    }

    func testEditingRotorExecutesSelectedEditingChordThenExitsQuickNavigation() async {
        let (_, adapter, sink, _, _) = makeAdapter()

        for _ in 0..<3 {
            adapter.beginTouchpadSwipeForTesting(x: -0.5)
            adapter.moveTouchpadForTesting(x: 0.1)
            adapter.endTouchpadSwipeForTesting()
        }
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .editing)

        adapter.receiveForTesting(input: .cross, pressed: true, at: 1.1)
        adapter.receiveForTesting(input: .cross, pressed: false, at: 1.2)
        await settle()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.control, true), .init(0x41, true),
                .init(0x41, false), .init(VK.control, false)
            ]
        )
        XCTAssertFalse(sink.transitions.contains { $0.key == VK.return })
        XCTAssertFalse(adapter.isQuickNavigationActiveForTesting)

        // The next Cross is the Base Enter mapping, not another Select All.
        adapter.receiveForTesting(input: .cross, pressed: true, at: 1.3)
        adapter.receiveForTesting(input: .cross, pressed: false, at: 1.4)
        await settle()
        XCTAssertEqual(
            Array(sink.transitions.suffix(2)),
            [.init(VK.return, true), .init(VK.return, false)]
        )
    }

    func testProfilesRotorActivatesSelectedProfileWithoutSendingEnter() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        let secondID = mappings.createProfile(name: "Hearthstone")

        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)
        adapter.beginTouchpadSwipeForTesting(x: -0.5)
        adapter.moveTouchpadForTesting(x: 0.1)
        adapter.endTouchpadSwipeForTesting()
        adapter.receiveForTesting(input: .rightStickDown, pressed: true, at: 1.1)
        adapter.receiveForTesting(input: .rightStickDown, pressed: false, at: 1.2)
        adapter.receiveForTesting(input: .cross, pressed: true, at: 1.3)
        adapter.receiveForTesting(input: .cross, pressed: false, at: 1.4)
        await settle()

        XCTAssertEqual(mappings.activeProfileID, secondID)
        XCTAssertTrue(sink.transitions.isEmpty)
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)

        // Profile activation clears transient touch state but preserves Quick
        // Navigation, so the next fresh one-finger contact must still rotate.
        adapter.beginTouchpadSwipeForTesting(x: -0.5)
        adapter.moveTouchpadForTesting(x: 0.1)
        adapter.endTouchpadSwipeForTesting()
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .controllerMapping)
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)

        adapter.beginTouchpadSwipeForTesting(x: -0.5)
        adapter.moveTouchpadForTesting(x: 0.1)
        adapter.endTouchpadSwipeForTesting()
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .editing)
    }

    func testControllerMappingRotorRequestsPresentationWithoutSendingRemoteInput() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        for _ in 0..<2 {
            adapter.beginTouchpadSwipeForTesting(x: -0.5)
            adapter.moveTouchpadForTesting(x: 0.1)
            adapter.endTouchpadSwipeForTesting()
        }
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .controllerMapping)
        XCTAssertEqual(adapter.controllerMappingRequestGeneration, 0)

        adapter.receiveForTesting(input: .cross, pressed: true, at: 1)
        adapter.receiveForTesting(input: .cross, pressed: false, at: 1.1)
        await settle()

        XCTAssertEqual(adapter.controllerMappingRequestGeneration, 1)
        XCTAssertFalse(adapter.isQuickNavigationActiveForTesting)
        XCTAssertTrue(sink.transitions.isEmpty)

        adapter.restoreQuickNavigationAfterControllerMapping()
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)
        XCTAssertEqual(adapter.quickNavigationCategoryForTesting, .controllerMapping)
    }

    func testRepeatLastQuickBarActionReplaysKeyboardActionWithoutSyntheticEnter() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(.farRelay(.repeatLastQuickBar), for: .triangle)
        mappings.setAction(nil, for: .circle)
        mappings.saveDraft()

        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)
        adapter.receiveForTesting(input: .cross, pressed: true, at: 1.1)
        adapter.receiveForTesting(input: .cross, pressed: false, at: 1.2)
        adapter.receiveForTesting(input: .circle, pressed: true, at: 1.3)
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1.4)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.5)
        await settle()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.lwin, true), .init(0x44, true), .init(0x44, false), .init(VK.lwin, false),
                .init(VK.lwin, true), .init(0x44, true), .init(0x44, false), .init(VK.lwin, false)
            ]
        )
        XCTAssertFalse(sink.transitions.contains { $0.key == VK.return })
    }

    func testProfileSwitchReleasesHeldActionBeforeNewMappingsBecomeActive() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        let firstID = mappings.activeProfileID
        let secondID = mappings.createProfile(name: "Hearthstone")
        XCTAssertTrue(mappings.beginEditing(profileID: secondID))
        mappings.setAction(.keyboard(.init(key: .tab)), for: .dpadUp)
        mappings.saveDraft()
        XCTAssertEqual(mappings.activeProfileID, firstID)

        adapter.receiveForTesting(input: .dpadUp, pressed: true, at: 1)
        await settle()
        adapter.receiveForTesting(input: .home, pressed: true, at: 1.1)
        adapter.receiveForTesting(input: .home, pressed: false, at: 1.2)
        await settle()

        XCTAssertEqual(mappings.activeProfileID, secondID)
        adapter.receiveForTesting(input: .dpadUp, pressed: false, at: 1.3)
        adapter.receiveForTesting(input: .dpadUp, pressed: true, at: 1.4)
        adapter.receiveForTesting(input: .dpadUp, pressed: false, at: 1.5)
        await settle()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.up, true), .init(VK.up, false),
                .init(VK.tab, true), .init(VK.tab, false)
            ]
        )
    }

    func testUnsupportedUnicodeUsesTheExplicitClipboardFallbackAndKeepsLedgerOwnership() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .touchpadPress, pressed: true, at: 1)
        _ = adapter.applyTextModeEditorValue("aé")
        await adapter.waitForTextOperationsForTesting()
        _ = adapter.applyTextModeEditorValue("a")
        await adapter.waitForTextOperationsForTesting()
        XCTAssertEqual(adapter.textModeBuffer, "a")
        XCTAssertEqual(sink.texts, ["é"])
        XCTAssertEqual(
            sink.transitions,
            [
                .init(0x41, true), .init(0x41, false),
                .init(VK.back, true), .init(VK.back, false)
            ]
        )
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
        XCTAssertEqual(sink.texts, [])
        XCTAssertEqual(
            sink.transitions,
            [
                .init(0x41, true), .init(0x41, false),
                .init(0x42, true), .init(0x42, false),
                .init(0x43, true), .init(0x43, false)
            ]
        )
        _ = adapter.applyTextModeEditorValue("abcSECRET_SENTINEL_123")
        await adapter.waitForTextOperationsForTesting()
        XCTAssertFalse(diagnostics.entries.contains { $0.result.contains("SECRET_SENTINEL_123") })
    }

    func testTextModeSlashAndQuestionMarkUseBalancedRawKeyboardTransitions() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .touchpadPress, pressed: true, at: 1)
        _ = adapter.applyTextModeEditorValue("/?")
        await adapter.waitForTextOperationsForTesting()

        XCTAssertEqual(sink.texts, [])
        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.oem2, true), .init(VK.oem2, false),
                .init(VK.shift, true), .init(VK.oem2, true), .init(VK.oem2, false), .init(VK.shift, false)
            ]
        )
    }

    func testTextModeSubmitSendsEnterAfterLiveTextThenExits() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .touchpadPress, pressed: true, at: 1)
        _ = adapter.applyTextModeEditorValue("ok")
        adapter.submitTextModeAndExit()
        await adapter.waitForTextOperationsForTesting()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(0x4F, true), .init(0x4F, false),
                .init(0x4B, true), .init(0x4B, false),
                .init(VK.return, true), .init(VK.return, false)
            ]
        )
        XCTAssertEqual(sink.texts, [])
        XCTAssertFalse(adapter.isTextModeActive)
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)
        XCTAssertEqual(adapter.textModeBuffer, "")
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

    func testQuickCommandModeIsLocalUntilExplicitSendAndRestoresQuickNavigation() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()

        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)

        XCTAssertTrue(adapter.isQuickCommandModeActive)
        XCTAssertFalse(adapter.isQuickNavigationActiveForTesting)

        adapter.updateQuickCommandBuffer("ctrl+v")
        await settle()
        XCTAssertTrue(sink.transitions.isEmpty)

        XCTAssertEqual(adapter.prepareQuickCommandForConfirmation(), "Control plus V")
        XCTAssertTrue(sink.transitions.isEmpty)
        XCTAssertTrue(adapter.confirmQuickCommand())
        await adapter.waitForQuickCommandForTesting()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.control, true), .init(0x56, true),
                .init(0x56, false), .init(VK.control, false)
            ]
        )
        XCTAssertFalse(adapter.isQuickCommandModeActive)
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)
    }

    func testQuickCommandSequenceExecutesChordTextAndEnterInOrder() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)

        adapter.updateQuickCommandBuffer("win+r,powershell,enter")
        XCTAssertNotNil(adapter.prepareQuickCommandForConfirmation())
        XCTAssertTrue(adapter.confirmQuickCommand())
        await adapter.waitForQuickCommandForTesting()

        let expectedPrefix: [ControllerTransition] = [
            .init(VK.lwin, true), .init(0x52, true),
            .init(0x52, false), .init(VK.lwin, false)
        ]
        XCTAssertEqual(Array(sink.transitions.prefix(4)), expectedPrefix)
        XCTAssertEqual(Array(sink.transitions.suffix(2)), [.init(VK.return, true), .init(VK.return, false)])

        // Literal text is one layout-independent Unicode transmission between
        // Win+R and Enter, rather than a series of host-layout VK events.
        XCTAssertEqual(sink.texts, ["powershell"])
        XCTAssertEqual(sink.transitions.count, 6)
    }

    func testQuickCommandWinRunExecutableTextSupportsPeriodAndExits() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)

        adapter.updateQuickCommandBuffer("win+r, msedge.exe,enter")
        XCTAssertEqual(
            adapter.prepareQuickCommandForConfirmation(),
            "Windows plus R. Then Type msedge.exe. Then Enter"
        )
        XCTAssertTrue(adapter.confirmQuickCommand())
        await adapter.waitForQuickCommandForTesting()

        XCTAssertEqual(sink.texts, ["msedge.exe"])
        XCTAssertEqual(
            Array(sink.transitions.suffix(2)),
            [.init(VK.return, true), .init(VK.return, false)]
        )
        XCTAssertFalse(adapter.isQuickCommandModeActive)
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)
    }

    func testQuickCommandHoldsFourModifiersUntilItsOneTargetReleases() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)

        adapter.updateQuickCommandBuffer("ctrl+shift+alt+win+s")
        XCTAssertNotNil(adapter.prepareQuickCommandForConfirmation())
        XCTAssertTrue(adapter.confirmQuickCommand())
        await adapter.waitForQuickCommandForTesting()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.control, true),
                .init(VK.shift, true),
                .init(VK.menu, true),
                .init(VK.lwin, true),
                .init(0x53, true),
                .init(0x53, false),
                .init(VK.lwin, false),
                .init(VK.menu, false),
                .init(VK.shift, false),
                .init(VK.control, false)
            ]
        )
    }

    func testQuickCommandSlashAndQuestionMarkUseOEM2NotRightBracket() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)

        adapter.updateQuickCommandBuffer("ctrl+/,ctrl+?")
        XCTAssertNotNil(adapter.prepareQuickCommandForConfirmation())
        XCTAssertTrue(adapter.confirmQuickCommand())
        await adapter.waitForQuickCommandForTesting()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.control, true), .init(VK.oem2, true), .init(VK.oem2, false), .init(VK.control, false),
                .init(VK.control, true), .init(VK.shift, true), .init(VK.oem2, true), .init(VK.oem2, false), .init(VK.shift, false), .init(VK.control, false),
            ]
        )
        XCTAssertFalse(sink.transitions.contains { $0.key == VK.oem6 })
    }

    func testTextModeClipboardPasteUsesExistingMirrorPipeline() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .touchpadPress, pressed: true, at: 1)
        adapter.receiveForTesting(input: .touchpadPress, pressed: false, at: 1.1)
        XCTAssertTrue(adapter.isTextModeActive)

        XCTAssertTrue(adapter.pasteTextIntoTextMode("clip"))
        await adapter.waitForTextOperationsForTesting()

        XCTAssertEqual(adapter.textModeBuffer, "clip")
        XCTAssertEqual(sink.texts, [])
        XCTAssertEqual(
            sink.transitions,
            [
                .init(0x43, true), .init(0x43, false),
                .init(0x4C, true), .init(0x4C, false),
                .init(0x49, true), .init(0x49, false),
                .init(0x50, true), .init(0x50, false)
            ]
        )
    }

    func testTextModeEmptyClipboardDoesNotMutateRemoteOrLocalState() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        adapter.receiveForTesting(input: .touchpadPress, pressed: true, at: 1)
        adapter.receiveForTesting(input: .touchpadPress, pressed: false, at: 1.1)

        XCTAssertFalse(adapter.pasteTextIntoTextMode(nil))
        await adapter.waitForTextOperationsForTesting()

        XCTAssertEqual(adapter.textModeBuffer, "")
        XCTAssertTrue(sink.transitions.isEmpty)
        XCTAssertTrue(sink.texts.isEmpty)
    }

    func testTextModePreservesFullPunctuationStringAcrossLayoutBoundary() async {
        let (_, adapter, sink, _, _) = makeAdapter()
        let punctuation = "/ ? [ ] { } \\ | ; : ' \" , < . > ` ~ - _ = + 1 ! 2 @ 3 # 4 $ 5 % 6 ^ 7 & 8 * 9 ( 0 )"
        adapter.receiveForTesting(input: .touchpadPress, pressed: true, at: 1)
        _ = adapter.applyTextModeEditorValue(punctuation)
        await adapter.waitForTextOperationsForTesting()

        XCTAssertEqual(sink.texts, [])
        XCTAssertFalse(sink.transitions.isEmpty)
        XCTAssertTrue(sink.transitions.contains(.init(VK.oem2, true)))
        XCTAssertTrue(sink.transitions.contains(.init(VK.shift, true)))
    }

    func testQuickCommandMultiModifierChordsKeepEveryModifierHeldForTarget() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)

        adapter.updateQuickCommandBuffer("ctrl+shift+tab,alt+shift+tab,ctrl+alt+delete,win+shift+s")
        XCTAssertNotNil(adapter.prepareQuickCommandForConfirmation())
        XCTAssertTrue(adapter.confirmQuickCommand())
        await adapter.waitForQuickCommandForTesting()

        XCTAssertEqual(
            sink.transitions,
            [
                .init(VK.control, true), .init(VK.shift, true), .init(VK.tab, true), .init(VK.tab, false), .init(VK.shift, false), .init(VK.control, false),
                .init(VK.menu, true), .init(VK.shift, true), .init(VK.tab, true), .init(VK.tab, false), .init(VK.shift, false), .init(VK.menu, false),
                .init(VK.control, true), .init(VK.menu, true), .init(VK.delete, true), .init(VK.delete, false), .init(VK.menu, false), .init(VK.control, false),
                .init(VK.lwin, true), .init(VK.shift, true), .init(0x53, true), .init(0x53, false), .init(VK.shift, false), .init(VK.lwin, false),
            ]
        )
    }

    func testQuickCommandRejectsMacModifierBeforeAnyWindowsInput() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)

        adapter.updateQuickCommandBuffer("cmd+v")
        XCTAssertNil(adapter.prepareQuickCommandForConfirmation())
        await settle()

        XCTAssertTrue(sink.transitions.isEmpty)
        XCTAssertTrue(adapter.isQuickCommandModeActive)
        XCTAssertEqual(adapter.quickCommandStatus, "Command is not available for Windows/NVDA Quick Command.")
    }

    func testQuickCommandParseFailureSendsNothingAndNeverLogsPayload() async {
        let (mappings, adapter, sink, _, diagnostics) = makeAdapter()
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)

        let secret = "SECRET_SENTINEL_42"
        adapter.updateQuickCommandBuffer("ctrl+" + secret)
        XCTAssertNil(adapter.prepareQuickCommandForConfirmation())
        await settle()

        XCTAssertTrue(sink.transitions.isEmpty)
        XCTAssertTrue(adapter.isQuickCommandModeActive)
        XCTAssertFalse(
            diagnostics.entries.contains { $0.result.contains(secret) || $0.reportLine.contains(secret) }
        )
    }

    func testQuickCommandCancelSendsNothingAndClearsLocalBuffer() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)

        adapter.updateQuickCommandBuffer("ctrl+v")
        adapter.exitQuickCommandMode()
        XCTAssertNil(adapter.prepareQuickCommandForConfirmation())
        await settle()

        XCTAssertTrue(sink.transitions.isEmpty)
        XCTAssertEqual(adapter.quickCommandBuffer, "")
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)
    }

    func testQuickCommandConfirmationPreviewSendsNothingUntilAlertSend() async {
        let (mappings, adapter, sink, _, diagnostics) = makeAdapter()
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)

        adapter.updateQuickCommandBuffer("win+r,powershell,enter")
        XCTAssertEqual(
            adapter.prepareQuickCommandForConfirmation(),
            "Windows plus R. Then Type powershell. Then Enter"
        )
        XCTAssertTrue(sink.transitions.isEmpty)
        XCTAssertTrue(adapter.isQuickCommandModeActive)
        XCTAssertEqual(adapter.quickCommandStatus, "Ready to confirm.")
        XCTAssertTrue(
            diagnostics.entries.contains {
                $0.result == "Quick Command: confirmation prepared; payload redacted"
            }
        )
    }

    func testQuickCommandAlertCancelKeepsModeAndBufferWithoutSending() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)

        adapter.updateQuickCommandBuffer("ctrl+v")
        XCTAssertEqual(adapter.prepareQuickCommandForConfirmation(), "Control plus V")
        adapter.cancelQuickCommandConfirmation()

        XCTAssertFalse(adapter.confirmQuickCommand())
        XCTAssertTrue(sink.transitions.isEmpty)
        XCTAssertTrue(adapter.isQuickCommandModeActive)
        XCTAssertEqual(adapter.quickCommandBuffer, "ctrl+v")
    }

    func testQuickCommandTransportFailureReleasesAlreadyPressedKeys() async {
        let (mappings, adapter, sink, _, _) = makeAdapter()
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)

        sink.lastInputForwardingResult = .rejected("test rejection")
        adapter.updateQuickCommandBuffer("ctrl+v")
        XCTAssertNotNil(adapter.prepareQuickCommandForConfirmation())
        XCTAssertTrue(adapter.confirmQuickCommand())
        await adapter.waitForQuickCommandForTesting()

        // Control-down is rejected after it is emitted by the existing NVDA
        // target; Quick Command must still issue the matching release.
        XCTAssertEqual(
            sink.transitions,
            [.init(VK.control, true), .init(VK.control, false)]
        )
        XCTAssertTrue(adapter.isQuickCommandModeActive)
        XCTAssertEqual(adapter.quickCommandStatus, "Quick Command failed.")
    }

    func testQuickCommandCapturesOriginalTargetLeaseAtSendTime() async {
        let defaults = makeDefaults()
        let mappings = ControllerMappingSettings(defaults: defaults)
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()
        let diagnostics = InputDiagnosticStore()
        diagnostics.isEnabled = true
        let firstSink = ControllerTestKeySink()
        let secondSink = ControllerTestKeySink()
        let router = RemoteIntentRouter()
        let firstID = NVDARemoteIntentTarget.defaultID
        let secondID = RemoteTargetID("nvda-second")
        router.register(NVDARemoteIntentTarget(keySink: firstSink, id: firstID))
        router.register(NVDARemoteIntentTarget(keySink: secondSink, id: secondID))
        XCTAssertTrue(router.setActiveTarget(id: firstID))
        let settings = AppSettings()
        let adapter = DualSenseControllerAdapter(
            mappings: mappings,
            settings: settings,
            router: router,
            diagnostics: diagnostics,
            feedback: InteractionFeedback(settings: settings)
        )

        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)
        adapter.updateQuickCommandBuffer("ctrl+v")
        XCTAssertEqual(adapter.prepareQuickCommandForConfirmation(), "Control plus V")

        // Opening confirmation captures the validated route. A later target
        // selection change must not redirect the exact command the alert showed.
        XCTAssertTrue(router.setActiveTarget(id: secondID))
        XCTAssertTrue(adapter.confirmQuickCommand())
        await adapter.waitForQuickCommandForTesting()

        XCTAssertFalse(firstSink.transitions.isEmpty)
        XCTAssertTrue(secondSink.transitions.isEmpty)
    }

    func testQuickCommandMacCommandVUsesRawHIDAndReturnsToQuickNavigation() async {
        let (adapter, macController, _) = makeMacQuickCommandAdapter()
        adapter.updateQuickCommandBuffer("cmd+v")

        XCTAssertNotNil(adapter.prepareQuickCommandForConfirmation())
        XCTAssertTrue(adapter.confirmQuickCommand())
        await adapter.waitForQuickCommandForTesting()

        XCTAssertEqual(
            macController.transitions,
            [
                .init(0xE3, true), .init(0x19, true),
                .init(0x19, false), .init(0xE3, false)
            ]
        )
        XCTAssertFalse(adapter.isQuickCommandModeActive)
        XCTAssertTrue(adapter.isQuickNavigationActiveForTesting)
    }

    func testQuickCommandMacLiteralTextUsesShiftedHIDAndRedactsPayload() async {
        let (adapter, macController, diagnostics) = makeMacQuickCommandAdapter()
        let payload = "Hi!"
        adapter.updateQuickCommandBuffer(payload)

        XCTAssertNotNil(adapter.prepareQuickCommandForConfirmation())
        XCTAssertTrue(adapter.confirmQuickCommand())
        await adapter.waitForQuickCommandForTesting()

        XCTAssertEqual(
            macController.transitions,
            [
                .init(0xE1, true), .init(0x0B, true), .init(0x0B, false), .init(0xE1, false),
                .init(0x0C, true), .init(0x0C, false),
                .init(0xE1, true), .init(0x1E, true), .init(0x1E, false), .init(0xE1, false)
            ]
        )
        XCTAssertFalse(
            diagnostics.entries.contains {
                $0.result.contains(payload) || $0.reportLine.contains(payload)
            }
        )
    }

    func testQuickCommandMacRejectsWindowsAndNvdaModifiersBeforeInput() {
        for command in ["win+r", "nvda+n"] {
            let (adapter, macController, _) = makeMacQuickCommandAdapter()
            adapter.updateQuickCommandBuffer(command)

            XCTAssertNil(adapter.prepareQuickCommandForConfirmation(), command)
            XCTAssertTrue(macController.transitions.isEmpty, command)
            XCTAssertTrue(adapter.isQuickCommandModeActive, command)
        }
    }

    func testQuickCommandMacAltAliasMapsToOption() async {
        let (adapter, macController, _) = makeMacQuickCommandAdapter()
        adapter.updateQuickCommandBuffer("alt+left")

        XCTAssertNotNil(adapter.prepareQuickCommandForConfirmation())
        XCTAssertTrue(adapter.confirmQuickCommand())
        await adapter.waitForQuickCommandForTesting()

        XCTAssertEqual(
            macController.transitions,
            [
                .init(0xE2, true), .init(0x50, true),
                .init(0x50, false), .init(0xE2, false)
            ]
        )
    }

    func testQuickCommandMacRejectsUnsupportedF13BeforeAnyInput() {
        let (adapter, macController, _) = makeMacQuickCommandAdapter()
        adapter.updateQuickCommandBuffer("cmd+f13")

        XCTAssertNil(adapter.prepareQuickCommandForConfirmation())
        XCTAssertTrue(macController.transitions.isEmpty)
        XCTAssertTrue(adapter.isQuickCommandModeActive)
    }

    func testAdapterPublishesTwentyThenTenPercentBatteryAlertsOnce() {
        let (_, adapter, _, _, _) = makeAdapter()

        adapter.receiveBatteryForTesting(percent: 20, isCharging: false)
        XCTAssertEqual(adapter.pendingBatteryAlert?.level, .twentyPercent)
        adapter.dismissBatteryAlert()

        adapter.receiveBatteryForTesting(percent: 19, isCharging: false)
        XCTAssertNil(adapter.pendingBatteryAlert)

        adapter.receiveBatteryForTesting(percent: 10, isCharging: false)
        XCTAssertEqual(adapter.pendingBatteryAlert?.level, .tenPercent)
        adapter.dismissBatteryAlert()

        adapter.receiveBatteryForTesting(percent: 9, isCharging: false)
        XCTAssertNil(adapter.pendingBatteryAlert)
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

    private func makeMacQuickCommandAdapter() -> (
        DualSenseControllerAdapter,
        ControllerTestMacRemoteController,
        InputDiagnosticStore
    ) {
        let defaults = makeDefaults()
        let mappings = ControllerMappingSettings(defaults: defaults)
        mappings.setAction(.farRelay(.quickCommandMode), for: .triangle)
        mappings.saveDraft()
        let diagnostics = InputDiagnosticStore()
        diagnostics.isEnabled = true
        let controller = ControllerTestMacRemoteController()
        let router = RemoteIntentRouter()
        router.register(MacRemoteIntentTarget(controller: controller))
        XCTAssertTrue(router.setActiveTarget(id: MacRemoteIntentTarget.defaultID))
        let settings = AppSettings()
        let adapter = DualSenseControllerAdapter(
            mappings: mappings,
            settings: settings,
            router: router,
            diagnostics: diagnostics,
            feedback: InteractionFeedback(settings: settings)
        )
        adapter.receiveForTesting(input: .triangle, pressed: true, at: 1)
        adapter.receiveForTesting(input: .triangle, pressed: false, at: 1.1)
        return (adapter, controller, diagnostics)
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
    var texts: [String] = []

    func sendKey(vk: UInt16, pressed: Bool) {
        transitions.append(.init(vk, pressed))
    }

    func sendText(_ text: String) -> InputForwardingResult {
        texts.append(text)
        return lastInputForwardingResult ?? .accepted
    }
}


private struct ControllerMacTransition: Equatable {
    let usage: UInt16
    let pressed: Bool

    init(_ usage: UInt16, _ pressed: Bool) {
        self.usage = usage
        self.pressed = pressed
    }
}

@MainActor
private final class ControllerTestMacRemoteController: MacRemoteIntentControlling {
    let activeProfile: HostProfile? = HostProfile(
        displayName: "Mac mini",
        platform: .macOS,
        macRemote: .init(isEnabled: true)
    )
    let remoteIntentConnectionState: HostTarget.ConnectionState = .ready
    var remoteIntentGeneration: UInt64? = 1
    private(set) var transitions: [ControllerMacTransition] = []

    func performMacRemoteAction(_ action: MacRemoteAction) async -> RemoteIntentResult {
        .performed
    }

    func performMacRemoteKeyTransition(
        _ key: MacRemoteKey,
        pressed: Bool
    ) async -> RemoteIntentResult {
        transitions.append(.init(key.usage, pressed))
        return .performed
    }
}
