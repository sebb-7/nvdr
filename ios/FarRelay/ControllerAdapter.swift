import Foundation
import GameController
import Observation
import UIKit

/// Owns Apple controller objects and turns their values into stable FarRelay
/// inputs. It deliberately has no SSH, NVDA, or host-protocol dependency.
@Observable @MainActor
final class DualSenseControllerAdapter {
    private let mappings: ControllerMappingSettings
    private let settings: AppSettings
    private let router: RemoteIntentRouter
    private let diagnostics: InputDiagnosticStore
    private let feedback: InteractionFeedback
    private var controller: GCController?
    private var connectObservation: NotificationCenter.ObservationToken?
    private var disconnectObservation: NotificationCenter.ObservationToken?
    private var inputLifecycle = ControllerInputLifecycle()
    private var layerEngine = ControllerLayerEngine()
    private var quickNavigation = QuickNavigationEngine()
    private var leftStick = ControllerStickDirectionClassifier(
        left: .leftStickLeft, right: .leftStickRight,
        up: .leftStickUp, down: .leftStickDown
    )
    private var rightStick = ControllerStickDirectionClassifier(
        left: .rightStickLeft, right: .rightStickRight,
        up: .rightStickUp, down: .rightStickDown
    )
    private struct ActiveAction {
        let input: ControllerInput
        let eventID: Int
        let action: KeyboardAction
        let route: RemoteIntentRoute
    }

    private var activeActions: [ControllerInput: ActiveAction] = [:]
    private var repeatTask: Task<Void, Never>?
    private var textOperationTail: Task<Void, Never>?
    private var textOperationGeneration = 0
    private var textMirrorSession = TextModeMirrorSession()
    private var nextDiagnosticEventID = 1

    private(set) var isTextModeActive = false
    private(set) var textModeBuffer = ""
    var layerStateForTesting: ControllerLayerEngine.State { layerEngine.state }
    var isQuickNavigationActiveForTesting: Bool { quickNavigation.isActive }

    private(set) var connectedControllerName: String?
    /// This is the real surface of the currently attached controller. An
    /// unpaired controller leaves the profile editable but marks every input
    /// as runtime-unavailable rather than pretending it can be pressed.
    private(set) var availableInputs: Set<ControllerInput> = []
    /// Bindings follow GameController's logical elements. This flags when iOS
    /// has remapped them so the mapping screen can state that semantic clearly.
    private(set) var controllerHasRemappedElements = false

    init(
        mappings: ControllerMappingSettings,
        settings: AppSettings,
        router: RemoteIntentRouter,
        diagnostics: InputDiagnosticStore,
        feedback: InteractionFeedback
    ) {
        self.mappings = mappings
        self.settings = settings
        self.router = router
        self.diagnostics = diagnostics
        self.feedback = feedback
        mappings.willChangeActiveProfile = { [weak self] in self?.releaseActiveActions() }
    }

    func start() {
        guard connectObservation == nil, disconnectObservation == nil else { return }
        connectObservation = NotificationCenter.default.addObserver(
            of: GCController.self, for: .didConnect
        ) { [weak self] message in
            self?.attach(message.controller)
        }
        disconnectObservation = NotificationCenter.default.addObserver(
            of: GCController.self, for: .didDisconnect
        ) { [weak self] message in
            self?.detach(message.controller)
        }
        GCController.controllers().forEach(attach)
    }

    func stop() {
        releaseActiveActions()
        isTextModeActive = false
        if let connectObservation { NotificationCenter.default.removeObserver(connectObservation) }
        if let disconnectObservation { NotificationCenter.default.removeObserver(disconnectObservation) }
        connectObservation = nil
        disconnectObservation = nil
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = nil
        connectedControllerName = nil
        availableInputs = []
        controllerHasRemappedElements = false
    }

    private func attach(_ candidate: GCController) {
        guard controller == nil, let gamepad = candidate.extendedGamepad else { return }
        controller = candidate
        connectedControllerName = candidate.vendorName ?? "Controller"
        availableInputs = inputsExposed(by: gamepad)
        controllerHasRemappedElements = gamepad.hasRemappedElements
        gamepad.valueChangedHandler = { [weak self] gamepad, element in
            Task { @MainActor in self?.process(element: element, gamepad: gamepad) }
        }
    }

    private func detach(_ candidate: GCController) {
        guard candidate == controller else { return }
        releaseActiveActions()
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = nil
        connectedControllerName = nil
        availableInputs = []
        controllerHasRemappedElements = false
    }

    private func process(element: GCControllerElement, gamepad: GCExtendedGamepad) {
        let now = ProcessInfo.processInfo.systemUptime
        controllerHasRemappedElements = gamepad.hasRemappedElements
        if let input = buttonInput(for: element, gamepad: gamepad), let button = element as? GCControllerButtonInput {
            handle(inputLifecycle.receive(input, pressed: button.isPressed, at: now))
        }

        // GCExtendedGamepad reports the containing GCControllerDirectionPad
        // when one of its directional subelements changes. Sample the four
        // D-pad buttons on every profile callback instead of depending on a
        // child GCControllerButtonInput being delivered as the changed element.
        receiveDpadState(
            up: gamepad.dpad.up.isPressed,
            down: gamepad.dpad.down.isPressed,
            left: gamepad.dpad.left.isPressed,
            right: gamepad.dpad.right.isPressed,
            at: now
        )

        // Reading the thumbstick axes on every profile callback gives one
        // stable, hysteretic source for stick-direction mappings.
        handle(leftStick.update(
            x: gamepad.leftThumbstick.xAxis.value,
            y: gamepad.leftThumbstick.yAxis.value,
            at: now
        ))
        handle(rightStick.update(
            x: gamepad.rightThumbstick.xAxis.value,
            y: gamepad.rightThumbstick.yAxis.value,
            at: now
        ))
    }

    private func handle(_ phases: [ControllerInputPhase]) {
        for phase in phases {
            switch phase {
            case .pressed(let input):
                let eventID = diagnosticEventID()
                diagnostics.observeController(eventID: eventID, input: input, pressed: true, stage: "GameController reception: pressed")
                if let layer = layerControlAction(for: input) {
                    present(layerEngine.press(layerID: layer.layerID, at: ProcessInfo.processInfo.systemUptime))
                    continue
                }
                if handleModeInput(input, pressed: true, eventID: eventID) { continue }
                guard let action = resolvedAction(for: input) else {
                    diagnostics.observeController(eventID: eventID, input: input, pressed: true, stage: "Binding lookup: no saved mapping")
                    continue
                }
                let started = start(action: action, input: input, eventID: eventID)
                if started, case .keyboard = action, let stateChange = layerEngine.consumeOneShotAfterResolvedAction() {
                    present(stateChange)
                }
            case .repeated(let input):
                guard let active = activeActions[input] else { continue }
                diagnostics.observeController(eventID: active.eventID, input: input, pressed: true, stage: "GameController lifecycle: repeat")
                route(active, transition: .repeated)
            case .released(let input):
                if layerControlAction(for: input) != nil {
                    releaseLayerControl(input)
                    continue
                }
                guard let active = activeActions.removeValue(forKey: input) else { continue }
                diagnostics.observeController(eventID: active.eventID, input: input, pressed: false, stage: "GameController reception: released")
                route(active, transition: .released)
            }
        }
        stopRepeatLoopIfIdle()
    }

    private func resolvedAction(for input: ControllerInput) -> ControllerAction? {
        mappings.activeProfile.action(for: input, layerID: layerEngine.layerForAction())
    }

    @discardableResult
    private func start(action: ControllerAction, input: ControllerInput, eventID: Int) -> Bool {
        switch action {
        case .keyboard(let keyboard):
            diagnostics.observeController(eventID: eventID, input: input, pressed: true, stage: "Binding lookup: matched Keyboard primary key \(keyboard.key.label); modifiers \(keyboard.modifiers.map(\.label).sorted().joined(separator: ", ").ifEmpty("none")); profile \(mappings.activeProfile.id.uuidString); schema \(mappings.activeProfile.schemaVersion)")
            guard let targetID = router.activeTargetID, let routeLease = router.routeLease(for: targetID) else {
                diagnostics.observeController(eventID: eventID, input: input, pressed: true, stage: "Capability routing: no active target; no fallback")
                return false
            }
            let active = ActiveAction(input: input, eventID: eventID, action: keyboard, route: routeLease)
            activeActions[input] = active
            route(active, transition: .pressed)
            startRepeatLoopIfNeeded()
            return true
        case .layer(let layer):
            present(layerEngine.press(layerID: layer.layerID, at: ProcessInfo.processInfo.systemUptime))
            return true
        case .quickNavigation:
            announce(quickNavigation.toggle())
            return true
        case .farRelay(.textMode):
            setTextMode(!isTextModeActive)
            return true
        }
    }

    /// Returns true if a local mode fully consumed the input.
    private func handleModeInput(_ input: ControllerInput, pressed: Bool, eventID: Int) -> Bool {
        if isTextModeActive {
            switch input {
            case .touchpadPress, .circle:
                setTextMode(false)
            case .rightStickPress:
                sendTextModeRemoteBackspace()
            default:
                diagnostics.observeController(eventID: eventID, input: input, pressed: pressed, stage: "Text Mode: controller input gated")
            }
            return true
        }
        if quickNavigation.isActive {
            switch input {
            case .create, .circle:
                announce(quickNavigation.exit() ?? "Quick Navigation off.")
            case .dpadLeft:
                announce(quickNavigation.previousCategory())
            case .dpadRight:
                announce(quickNavigation.nextCategory())
            case .rightStickUp:
                if quickNavigation.category == .quickBar {
                    announce(quickNavigation.previousQuickBarAction())
                } else if let key = quickNavigation.category.key {
                    start(
                        action: .keyboard(.init(key: key, modifiers: [.shift])),
                        input: input,
                        eventID: eventID
                    )
                }
            case .rightStickDown:
                if quickNavigation.category == .quickBar {
                    announce(quickNavigation.nextQuickBarAction())
                } else if let key = quickNavigation.category.key {
                    start(action: .keyboard(.init(key: key)), input: input, eventID: eventID)
                }
            case .cross:
                if quickNavigation.category == .quickBar {
                    start(
                        action: .keyboard(quickNavigation.selectedQuickBarAction.keyboardAction),
                        input: input,
                        eventID: eventID
                    )
                } else {
                    start(action: .keyboard(.init(key: .enter)), input: input, eventID: eventID)
                }
            default:
                return false
            }
            return true
        }
        return false
    }

    private func layerControlAction(for input: ControllerInput) -> ControllerLayerAction? {
        guard case .layer(let layer)? = mappings.activeProfile.action(for: input) else { return nil }
        return layer
    }

    private func releaseLayerControl(_ input: ControllerInput) {
        guard let layer = layerControlAction(for: input) else { return }
        if let stateChange = layerEngine.release(layerID: layer.layerID, at: ProcessInfo.processInfo.systemUptime) {
            present(stateChange)
        }
    }

    private func setTextMode(_ active: Bool) {
        isTextModeActive = active
        textMirrorSession.reset()
        textModeBuffer = ""
        cancelTextOperations()
        if active { _ = quickNavigation.exit() }
        if !active { releaseActiveActions() }
        announce(active ? "Text Mode" : "Text Mode off")
    }

    func exitTextMode() { setTextMode(false) }

    /// Mirrors local BSI/editor deltas one character at a time through the
    /// same router used by controller bindings. It intentionally records only
    /// counts and outcomes, never text content.
    /// Text Mode v1 deliberately accepts append-at-end and suffix deletion
    /// only. Other edits are rejected locally instead of guessing a remote
    /// cursor operation from a whole-string diff.
    @discardableResult
    func applyTextModeEditorValue(_ proposedValue: String) -> String {
        guard isTextModeActive else { return textModeBuffer }
        let old = Array(textModeBuffer)
        let proposed = Array(proposedValue)
        if proposed.starts(with: old) {
            mirrorTextInsertion(Array(proposed.dropFirst(old.count)))
        } else if old.starts(with: proposed) {
            mirrorTextBackspace(count: old.count - proposed.count)
        } else {
            announce("Text Mode supports appending and deleting from the end")
        }
        return textModeBuffer
    }

    func mirrorTextInsertion(_ characters: [Character]) {
        guard isTextModeActive else { return }
        var unsupported = 0
        for character in characters {
            if let action = ControllerTextCharacterMapper.action(for: character) {
                textMirrorSession.append(character, mirrored: true)
                enqueueTextTap(action, diagnostic: "Text Mode: character transmitted")
            } else {
                textMirrorSession.append(character, mirrored: false)
                unsupported += 1
            }
        }
        textModeBuffer = textMirrorSession.text
        if unsupported > 0 {
            announce("Unsupported character")
            diagnostics.observe(source: .controller, result: "Text Mode: \(unsupported) unsupported character")
        }
    }

    func mirrorTextBackspace(count: Int = 1) {
        guard isTextModeActive, count > 0 else { return }
        let remoteBackspaces = textMirrorSession.deleteSuffix(count: count)
        textModeBuffer = textMirrorSession.text
        for _ in 0..<remoteBackspaces {
            enqueueTextTap(.init(key: .backspace), diagnostic: "Text Mode: remote backspace transmitted")
        }
    }

    /// Native BSI deletion can still call deleteBackward when the local editor
    /// is empty. In that state there is no local session character to remove,
    /// so one Backspace is intentionally forwarded to pre-existing remote text.
    func handleTextModeDeleteBackwardWhenLocalBufferEmpty() {
        guard isTextModeActive, textModeBuffer.isEmpty else { return }
        sendTextModeRemoteBackspace()
    }

    private func sendTextModeRemoteBackspace() {
        guard isTextModeActive else { return }
        if textMirrorSession.remoteBackspace() { textModeBuffer = textMirrorSession.text }
        enqueueTextTap(.init(key: .backspace), diagnostic: "Text Mode: remote backspace transmitted")
    }

    private func enqueueTextTap(_ action: KeyboardAction, diagnostic: String) {
        let previous = textOperationTail
        let generation = textOperationGeneration
        textOperationTail = Task { @MainActor [weak self, previous] in
            _ = await previous?.value
            guard let self, generation == self.textOperationGeneration, !Task.isCancelled else { return }
            await self.routeTextTap(action, diagnostic: diagnostic)
        }
    }

    private func cancelTextOperations() {
        textOperationGeneration += 1
        textOperationTail?.cancel()
        textOperationTail = nil
    }

    private func routeTextTap(_ action: KeyboardAction, diagnostic: String) async {
        guard let targetID = router.activeTargetID else {
            diagnostics.observe(source: .controller, result: "\(diagnostic); no active target")
            return
        }
        let key = RemoteKey.windowsVirtualKey(action.key.virtualKey)
        let modifiers = resolvedModifiers(action.modifiers)
        let intent: RemoteIntent = modifiers.isEmpty
            ? .sendKey(key)
            : .sendChord(.init(modifiers: modifiers, key: key))
        diagnostics.observe(source: .controller, result: diagnostic)
        _ = await router.route(intent, to: targetID)
    }

    private func present(_ stateChange: LayerFeedback) {
        let kind: InteractionFeedbackKind = switch stateChange {
        case .activated, .oneShot: .selectionAccepted
        case .locked: .success
        case .base: .warning
        }
        feedback.play(kind)
        announce(stateChange.announcement)
    }

    private func announce(_ text: String) {
        diagnostics.observe(source: .controller, result: text)
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private enum ActionTransition { case pressed, repeated, released }

    private func route(_ active: ActiveAction, transition: ActionTransition) {
        let action = active.action
        let key = RemoteKey.windowsVirtualKey(action.key.virtualKey)
        let modifiers = resolvedModifiers(action.modifiers)
        let intent: RemoteIntent
        switch (modifiers.isEmpty, transition) {
        case (true, .pressed): intent = .sendKeyTransition(key, pressed: true)
        case (true, .repeated): intent = .repeatKey(key)
        case (true, .released): intent = .sendKeyTransition(key, pressed: false)
        case (false, .pressed): intent = .sendChordTransition(.init(modifiers: modifiers, key: key), pressed: true)
        case (false, .repeated): intent = .repeatChord(.init(modifiers: modifiers, key: key))
        case (false, .released): intent = .sendChordTransition(.init(modifiers: modifiers, key: key), pressed: false)
        }
        let stage = switch transition {
        case .pressed: "press"
        case .repeated: "repeat"
        case .released: "release"
        }
        let pressed = stage != "release"
        diagnostics.observeController(
            eventID: active.eventID,
            input: active.input,
            pressed: pressed,
            stage: "RemoteIntent created: \(stage) keyboard virtual key \(action.key.virtualKey)"
        )
        guard let target = router.target(for: active.route) else {
            diagnostics.observeController(eventID: active.eventID, input: active.input, pressed: pressed, stage: "Capability routing: original target unavailable; no fallback")
            return
        }
        guard target.capabilities.contains(intent.requiredCapability) else {
            diagnostics.observeController(eventID: active.eventID, input: active.input, pressed: pressed, stage: "Capability routing: target \(target.id.rawValue) unsupported; no fallback")
            return
        }
        diagnostics.observeController(eventID: active.eventID, input: active.input, pressed: pressed, stage: "Capability routing: supported; target \(target.displayName); executor \(target.kind.rawValue)")
        Task { @MainActor [router, diagnostics, route = active.route, input = active.input, eventID = active.eventID] in
            let result = await router.route(intent, via: route)
            let completion: String = switch result {
            case .performed:
                "Transport: queued; host receipt/execution: unconfirmed by the existing IPC protocol"
            case .unsupported:
                "Capability routing: executor reported unsupported; no fallback"
            case .unavailable(let reason):
                "Executor unavailable: \(reason)"
            case .failed(let reason):
                "Transport/execution failed: \(reason)"
            }
            diagnostics.observeController(eventID: eventID, input: input, pressed: pressed, stage: completion)
        }
    }

    /// Test seam for deterministic controller-pipeline coverage. Production
    /// controller callbacks enter the same lifecycle through `process`.
    func receiveForTesting(input: ControllerInput, pressed: Bool, at time: TimeInterval) {
        handle(inputLifecycle.receive(input, pressed: pressed, at: time))
    }

    /// Test seam for the production D-pad normalization path.
    func receiveDpadForTesting(
        up: Bool,
        down: Bool,
        left: Bool,
        right: Bool,
        at time: TimeInterval
    ) {
        receiveDpadState(up: up, down: down, left: left, right: right, at: time)
    }

    func waitForTextOperationsForTesting() async {
        await textOperationTail?.value
    }

    private func receiveDpadState(
        up: Bool,
        down: Bool,
        left: Bool,
        right: Bool,
        at time: TimeInterval
    ) {
        let states: [(ControllerInput, Bool)] = [
            (.dpadUp, up),
            (.dpadDown, down),
            (.dpadLeft, left),
            (.dpadRight, right)
        ]
        for (input, pressed) in states {
            handle(inputLifecycle.receive(input, pressed: pressed, at: time))
        }
    }

    private func diagnosticEventID() -> Int {
        defer { nextDiagnosticEventID += 1 }
        return nextDiagnosticEventID
    }

    private func startRepeatLoopIfNeeded() {
        guard repeatTask == nil else { return }
        repeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard !Task.isCancelled, let self else { return }
                self.handle(self.inputLifecycle.repeatEvents(at: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    private func stopRepeatLoopIfIdle() {
        guard activeActions.isEmpty else { return }
        repeatTask?.cancel()
        repeatTask = nil
    }

    private func releaseActiveActions() {
        let actions = ControllerInput.allCases.compactMap { input in
            activeActions[input].map { (input, $0) }
        }
        activeActions.removeAll()
        _ = inputLifecycle.releaseAll()
        leftStick.reset()
        rightStick.reset()
        layerEngine.reset()
        _ = quickNavigation.exit()
        isTextModeActive = false
        textMirrorSession.reset()
        textModeBuffer = ""
        cancelTextOperations()
        repeatTask?.cancel()
        repeatTask = nil
        for (_, active) in actions { route(active, transition: .released) }
    }

    private func resolvedModifiers(_ modifiers: Set<ControllerKeyboardModifier>) -> Set<RemoteModifier> {
        modifiers.reduce(into: []) { result, modifier in
            switch modifier {
            case .shift: result.insert(.shift)
            case .control: result.insert(.control)
            case .alt: result.insert(.alt)
            case .windows: result.insert(.commandOrWindows)
            case .nvda:
                switch settings.nvdaModifier {
                case .capsLock: result.insert(.capsLock)
                case .voKeys: result.formUnion([.control, .alt])
                }
            }
        }
    }

    private func inputsExposed(by gamepad: GCExtendedGamepad) -> Set<ControllerInput> {
        var inputs: Set<ControllerInput> = [
            .dpadUp, .dpadDown, .dpadLeft, .dpadRight,
            .cross, .circle, .square, .triangle,
            .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger,
            .leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight,
            .rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight,
            .create
        ]
        if gamepad.buttonOptions != nil { inputs.insert(.options) }
        if gamepad.buttonHome != nil { inputs.insert(.home) }
        if gamepad.leftThumbstickButton != nil { inputs.insert(.leftStickPress) }
        if gamepad.rightThumbstickButton != nil { inputs.insert(.rightStickPress) }
        if gamepad is GCDualSenseGamepad { inputs.insert(.touchpadPress) }
        return inputs
    }

    private func buttonInput(for element: GCControllerElement, gamepad: GCExtendedGamepad) -> ControllerInput? {
        if element === gamepad.buttonA { return .cross }
        if element === gamepad.buttonB { return .circle }
        if element === gamepad.buttonX { return .square }
        if element === gamepad.buttonY { return .triangle }
        if element === gamepad.leftShoulder { return .leftShoulder }
        if element === gamepad.rightShoulder { return .rightShoulder }
        if element === gamepad.leftTrigger { return .leftTrigger }
        if element === gamepad.rightTrigger { return .rightTrigger }
        if element === gamepad.buttonMenu { return .create }
        if let options = gamepad.buttonOptions, element === options { return .options }
        if let home = gamepad.buttonHome, element === home { return .home }
        if let leftStick = gamepad.leftThumbstickButton, element === leftStick { return .leftStickPress }
        if let rightStick = gamepad.rightThumbstickButton, element === rightStick { return .rightStickPress }
        if let dualSense = gamepad as? GCDualSenseGamepad, element === dualSense.touchpadButton { return .touchpadPress }
        return nil
    }
}

private extension String {
    func ifEmpty(_ replacement: @autoclosure () -> String) -> String {
        isEmpty ? replacement() : self
    }
}
