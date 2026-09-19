import Foundation
import GameController
import Observation

/// Owns Apple controller objects and turns their values into stable FarRelay
/// inputs. It deliberately has no SSH, NVDA, or host-protocol dependency.
@Observable @MainActor
final class DualSenseControllerAdapter {
    private let mappings: ControllerMappingSettings
    private let settings: AppSettings
    private let router: RemoteIntentRouter
    private let diagnostics: InputDiagnosticStore
    private var controller: GCController?
    private var connectObservation: NotificationCenter.ObservationToken?
    private var disconnectObservation: NotificationCenter.ObservationToken?
    private var inputLifecycle = ControllerInputLifecycle()
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
        let targetID: RemoteTargetID
    }

    private var activeActions: [ControllerInput: ActiveAction] = [:]
    private var repeatTask: Task<Void, Never>?
    private var nextDiagnosticEventID = 1

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
        diagnostics: InputDiagnosticStore
    ) {
        self.mappings = mappings
        self.settings = settings
        self.router = router
        self.diagnostics = diagnostics
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

        // Direction-pad child callbacks are not consistent across controller
        // families. Reading the axes on every profile callback gives one
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
                guard case .keyboard(let action)? = mappings.activeProfile.action(for: input) else {
                    diagnostics.observeController(eventID: eventID, input: input, pressed: true, stage: "Binding lookup: no saved mapping")
                    continue
                }
                diagnostics.observeController(eventID: eventID, input: input, pressed: true, stage: "Binding lookup: matched Keyboard primary key \(action.key.label); modifiers \(action.modifiers.map(\.label).sorted().joined(separator: ", ").ifEmpty("none")); profile \(mappings.activeProfile.id.uuidString); schema \(mappings.activeProfile.schemaVersion)")
                guard let targetID = router.activeTargetID else {
                    diagnostics.observeController(eventID: eventID, input: input, pressed: true, stage: "Capability routing: no active target; no fallback")
                    continue
                }
                let active = ActiveAction(input: input, eventID: eventID, action: action, targetID: targetID)
                activeActions[input] = active
                route(active, transition: .pressed)
                startRepeatLoopIfNeeded()
            case .repeated(let input):
                guard let active = activeActions[input] else { continue }
                diagnostics.observeController(eventID: active.eventID, input: input, pressed: true, stage: "GameController lifecycle: repeat")
                route(active, transition: .repeated)
            case .released(let input):
                guard let active = activeActions.removeValue(forKey: input) else { continue }
                diagnostics.observeController(eventID: active.eventID, input: input, pressed: false, stage: "GameController reception: released")
                route(active, transition: .released)
            }
        }
        stopRepeatLoopIfIdle()
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
        guard let target = router.target(for: active.targetID) else {
            diagnostics.observeController(eventID: active.eventID, input: active.input, pressed: pressed, stage: "Capability routing: original target unavailable; no fallback")
            return
        }
        guard target.capabilities.contains(intent.requiredCapability) else {
            diagnostics.observeController(eventID: active.eventID, input: active.input, pressed: pressed, stage: "Capability routing: target \(target.id.rawValue) unsupported; no fallback")
            return
        }
        diagnostics.observeController(eventID: active.eventID, input: active.input, pressed: pressed, stage: "Capability routing: supported; target \(target.displayName); executor \(target.kind.rawValue)")
        Task { @MainActor [router, diagnostics, targetID = active.targetID, input = active.input, eventID = active.eventID] in
            let result = await router.route(intent, to: targetID)
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
        if element === gamepad.dpad.up { return .dpadUp }
        if element === gamepad.dpad.down { return .dpadDown }
        if element === gamepad.dpad.left { return .dpadLeft }
        if element === gamepad.dpad.right { return .dpadRight }
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
