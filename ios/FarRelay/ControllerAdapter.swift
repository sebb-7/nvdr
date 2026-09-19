import Foundation
import GameController
import Observation

/// Owns Apple controller objects and turns their values into stable FarRelay inputs.
/// It deliberately has no SSH, NVDA, or host-protocol dependency.
@Observable @MainActor
final class DualSenseControllerAdapter {
    private let mappings: ControllerMappingSettings
    private let router: RemoteIntentRouter
    private var controller: GCController?
    private var connectObservation: NotificationCenter.ObservationToken?
    private var disconnectObservation: NotificationCenter.ObservationToken?
    private(set) var connectedControllerName: String?

    init(mappings: ControllerMappingSettings, router: RemoteIntentRouter) {
        self.mappings = mappings
        self.router = router
    }

    func start() {
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
        if let connectObservation { NotificationCenter.default.removeObserver(connectObservation) }
        if let disconnectObservation { NotificationCenter.default.removeObserver(disconnectObservation) }
        connectObservation = nil
        disconnectObservation = nil
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = nil
        connectedControllerName = nil
    }

    private func attach(_ candidate: GCController) {
        guard controller == nil, let gamepad = candidate.extendedGamepad else { return }
        controller = candidate
        connectedControllerName = candidate.vendorName ?? "Controller"
        gamepad.valueChangedHandler = { [weak self] gamepad, element in
            Task { @MainActor in self?.process(element: element, gamepad: gamepad) }
        }
    }

    private func detach(_ candidate: GCController) {
        guard candidate == controller else { return }
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = nil
        connectedControllerName = nil
    }

    private func process(element: GCControllerElement, gamepad: GCExtendedGamepad) {
        guard let input = input(for: element, gamepad: gamepad), let button = element as? GCControllerButtonInput else { return }
        guard button.isPressed, case .keyboard(let action)? = mappings.activeProfile.action(for: input) else { return }
        let key = RemoteKey.windowsVirtualKey(action.key.virtualKey)
        let modifiers = resolvedModifiers(action.modifiers)
        Task { @MainActor in
            let intent: RemoteIntent = modifiers.isEmpty ? .sendKey(key) : .sendChord(.init(modifiers: modifiers, key: key))
            _ = await router.route(intent)
        }
    }

    private func resolvedModifiers(_ modifiers: Set<ControllerKeyboardModifier>) -> Set<RemoteModifier> {
        modifiers.reduce(into: []) { result, modifier in
            switch modifier {
            case .shift: result.insert(.shift)
            case .control: result.insert(.control)
            case .alt: result.insert(.alt)
            case .windows: result.insert(.commandOrWindows)
            case .nvda:
                switch AppSettings().nvdaModifier { case .capsLock: break; case .voKeys: result.formUnion([.control, .alt]) }
            }
        }
    }

    private func input(for element: GCControllerElement, gamepad: GCExtendedGamepad) -> ControllerInput? {
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
        if element === gamepad.leftThumbstick.up { return .leftStickUp }
        if element === gamepad.leftThumbstick.down { return .leftStickDown }
        if element === gamepad.leftThumbstick.left { return .leftStickLeft }
        if element === gamepad.leftThumbstick.right { return .leftStickRight }
        if element === gamepad.rightThumbstick.up { return .rightStickUp }
        if element === gamepad.rightThumbstick.down { return .rightStickDown }
        if element === gamepad.rightThumbstick.left { return .rightStickLeft }
        if element === gamepad.rightThumbstick.right { return .rightStickRight }
        if element === gamepad.buttonMenu { return .create }
        if let options = gamepad.buttonOptions, element === options { return .options }
        if let leftStick = gamepad.leftThumbstickButton, element === leftStick { return .leftStickPress }
        if let rightStick = gamepad.rightThumbstickButton, element === rightStick { return .rightStickPress }
        if let dualSense = gamepad as? GCDualSenseGamepad, element === dualSense.touchpadButton { return .touchpadPress }
        return nil
    }
}
