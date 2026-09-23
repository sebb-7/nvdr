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
    private var touchpadRotor = TouchpadRotorGesture()
    private var touchpad: GCControllerTouchpad?
    private var dualSenseTouchpadPrimary: GCControllerDirectionPad?
    private var touchpadContactActive = false
    private var touchpadContactSuppressed = false
    private var touchpadFallbackEndTask: Task<Void, Never>?
    private var didObserveDualSensePrimaryMovement = false
    private let controllerHaptics = ControllerHapticFeedback()
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

    private struct StickyModifierLease {
        let modifier: ControllerKeyboardModifier
        let ownerInput: ControllerInput
        let virtualKeys: [UInt16]
        let route: RemoteIntentRoute
        /// Non-nil when this hold was armed from a physically held Action
        /// Layer. Releasing that layer must release this modifier.
        let ownerLayerID: String?
    }

    private var activeActions: [ControllerInput: ActiveAction] = [:]
    private var stickyModifierLeases: [ControllerKeyboardModifier: StickyModifierLease] = [:]
    private var repeatTask: Task<Void, Never>?
    private var textOperationTail: Task<Void, Never>?
    private var textOperationGeneration = 0
    private var textMirrorSession = TextModeMirrorSession()
    private struct PreparedQuickCommand {
        let command: QuickCommand
        let preview: String
        let plan: [[QuickCommandTransmission]]
        let route: RemoteIntentRoute
    }

    private var quickCommandTask: Task<Void, Never>?
    private var quickCommandGeneration = 0
    private var preparedQuickCommand: PreparedQuickCommand?
    private var lastQuickBarAction: ControllerAction?
    private var nextDiagnosticEventID = 1

    private(set) var isTextModeActive = false
    private(set) var textModeBuffer = ""
    private(set) var isQuickCommandModeActive = false
    private(set) var quickCommandBuffer = ""
    private(set) var quickCommandStatus: String?
    var layerStateForTesting: ControllerLayerEngine.State { layerEngine.state }
    var isQuickNavigationActiveForTesting: Bool { quickNavigation.isActive }
    var quickNavigationCategoryForTesting: QuickNavigationCategory { quickNavigation.category }

    private(set) var connectedControllerName: String?
    private(set) var controllerStatus: ControllerDeviceStatus?
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
        mappings.willChangeActiveProfile = { [weak self] in
            self?.releaseActiveActions(exitQuickNavigation: false)
        }
    }

    func start() {
        guard connectObservation == nil, disconnectObservation == nil else { return }
        if !isTextModeActive && !isQuickCommandModeActive { _ = quickNavigation.activate() }
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
        isQuickCommandModeActive = false
        quickCommandBuffer = ""
        quickCommandStatus = nil
        preparedQuickCommand = nil
        cancelQuickCommand()
        if let connectObservation { NotificationCenter.default.removeObserver(connectObservation) }
        if let disconnectObservation { NotificationCenter.default.removeObserver(disconnectObservation) }
        connectObservation = nil
        disconnectObservation = nil
        controller?.extendedGamepad?.valueChangedHandler = nil
        clearTouchpadHandlers()
        controllerHaptics.detach()
        controller = nil
        connectedControllerName = nil
        controllerStatus = nil
        availableInputs = []
        controllerHasRemappedElements = false
    }

    private func attach(_ candidate: GCController) {
        guard controller == nil, let gamepad = candidate.extendedGamepad else { return }
        controller = candidate
        connectedControllerName = candidate.vendorName ?? "Controller"
        refreshControllerStatus(from: candidate)
        availableInputs = inputsExposed(by: gamepad)
        controllerHasRemappedElements = gamepad.hasRemappedElements
        gamepad.valueChangedHandler = { [weak self] gamepad, element in
            Task { @MainActor in self?.process(element: element, gamepad: gamepad) }
        }
        configureTouchpad(for: candidate)
        controllerHaptics.attach(to: candidate)
    }

    func refreshControllerStatus() {
        guard let controller else {
            controllerStatus = nil
            return
        }
        refreshControllerStatus(from: controller)
    }

    private func refreshControllerStatus(from candidate: GCController) {
        let battery = candidate.battery
        let batteryPercent = battery.map {
            Int((max(0, min(1, $0.batteryLevel)) * 100).rounded())
        }
        let batteryStateLabel: String?
        switch battery?.batteryState {
        case .charging?: batteryStateLabel = "Charging"
        case .discharging?: batteryStateLabel = "Discharging"
        case .full?: batteryStateLabel = "Full"
        case .unknown?, nil: batteryStateLabel = nil
        @unknown default: batteryStateLabel = nil
        }

        controllerStatus = ControllerDeviceStatus(
            name: candidate.vendorName ?? "Controller",
            batteryPercent: batteryPercent,
            batteryStateLabel: batteryStateLabel,
            supportsHaptics: candidate.haptics?.supportedLocalities.contains(.default) == true,
            supportsTouchpad:
                (candidate.extendedGamepad as? GCDualSenseGamepad) != nil ||
                !candidate.physicalInputProfile.touchpads.isEmpty
        )
    }

    private func configureTouchpad(for candidate: GCController) {
        resetTouchpadGesture()
        didObserveDualSensePrimaryMovement = false

        // Keep Apple's generic touchpad object for authoritative contact state
        // (down / moving / up) when it is exposed by the physical profile.
        if let touchpad = candidate.physicalInputProfile.touchpads.values.first {
            touchpad.reportsAbsoluteTouchSurfaceValues = true
            touchpad.preferredSystemGestureState = .alwaysReceive
            touchpad.touchSurface.preferredSystemGestureState = .alwaysReceive
            touchpad.button.preferredSystemGestureState = .alwaysReceive
            self.touchpad = touchpad

            touchpad.touchDown = { [weak self] _, x, _, _, _ in
                Task { @MainActor in
                    self?.receiveTouchpadContact(.down, x: x, source: "generic touchpad")
                }
            }
            touchpad.touchMoved = { [weak self] _, x, _, _, _ in
                Task { @MainActor in
                    self?.receiveTouchpadContact(.moving, x: x, source: "generic touchpad")
                }
            }
            touchpad.touchUp = { [weak self] _, x, _, _, _ in
                Task { @MainActor in
                    self?.receiveTouchpadContact(.up, x: x, source: "generic touchpad")
                }
            }
            diagnostics.observe(
                source: .controller,
                result: "Touchpad: generic contact-state path installed"
            )
        }

        // DualSense exposes the primary finger explicitly. Prefer listening to
        // that path as well because real devices can update touchpadPrimary
        // even when GCControllerTouchpad callbacks are delayed or absent.
        if let dualSense = candidate.extendedGamepad as? GCDualSenseGamepad {
            let primary = dualSense.touchpadPrimary
            primary.preferredSystemGestureState = .alwaysReceive
            dualSense.touchpadButton.preferredSystemGestureState = .alwaysReceive
            dualSenseTouchpadPrimary = primary
            primary.valueChangedHandler = { [weak self] _, x, _ in
                Task { @MainActor in
                    self?.receiveDualSensePrimaryTouchpad(x: x)
                }
            }
            diagnostics.observe(
                source: .controller,
                result: "Touchpad: DualSense primary-finger path installed"
            )
        }

        if touchpad == nil, dualSenseTouchpadPrimary == nil {
            diagnostics.observe(
                source: .controller,
                result: "Touchpad: no supported touch surface exposed by GameController"
            )
        }
    }

    private func clearTouchpadHandlers() {
        touchpad?.touchDown = nil
        touchpad?.touchMoved = nil
        touchpad?.touchUp = nil
        dualSenseTouchpadPrimary?.valueChangedHandler = nil
        touchpad = nil
        dualSenseTouchpadPrimary = nil
        didObserveDualSensePrimaryMovement = false
        resetTouchpadGesture()
    }

    private func receiveDualSensePrimaryTouchpad(x: Float) {
        if !didObserveDualSensePrimaryMovement {
            didObserveDualSensePrimaryMovement = true
            diagnostics.observe(
                source: .controller,
                result: "Touchpad: DualSense primary-finger movement received"
            )
        }

        if let touchpad {
            switch touchpad.touchState {
            case .down:
                receiveTouchpadContact(.down, x: x, source: "DualSense primary")
            case .moving:
                receiveTouchpadContact(.moving, x: x, source: "DualSense primary")
            case .up:
                receiveTouchpadContact(.up, x: x, source: "DualSense primary")
            @unknown default:
                resetTouchpadGesture()
            }
            return
        }

        // Very defensive fallback for a DualSense whose typed profile is
        // available while the generic touchpad collection is not. The first
        // movement establishes a contact; inactivity closes that contact.
        receiveTouchpadContact(.moving, x: x, source: "DualSense primary fallback")
        scheduleTouchpadFallbackEnd()
    }

    private func receiveTouchpadContact(
        _ phase: ControllerTouchpadContactPhase,
        x: Float,
        source: String
    ) {
        switch phase {
        case .down:
            touchpadFallbackEndTask?.cancel()
            touchpadFallbackEndTask = nil
            if !touchpadContactActive {
                touchpadContactActive = true
                touchpadContactSuppressed = isActionLayerActiveForTouchpad
                touchpadRotor.begin(x: x)
                return
            }
            if isActionLayerActiveForTouchpad {
                touchpadContactSuppressed = true
            }
            guard !touchpadContactSuppressed else { return }
            handleTouchpadMove(x: x, source: source)

        case .moving:
            if !touchpadContactActive {
                // Recover if Apple delivered movement before the down callback.
                touchpadContactActive = true
                touchpadContactSuppressed = isActionLayerActiveForTouchpad
                touchpadRotor.begin(x: x)
                diagnostics.observe(
                    source: .controller,
                    result: "Touchpad: recovered contact from movement"
                )
                return
            }
            if isActionLayerActiveForTouchpad {
                // Once a layer owns any part of this finger contact, keep the
                // remainder inert even if the layer is released before lift.
                touchpadContactSuppressed = true
            }
            guard !touchpadContactSuppressed else { return }
            handleTouchpadMove(x: x, source: source)

        case .up:
            resetTouchpadGesture()
        }
    }

    private func scheduleTouchpadFallbackEnd() {
        touchpadFallbackEndTask?.cancel()
        touchpadFallbackEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.resetTouchpadGesture()
        }
    }

    private var isActionLayerActiveForTouchpad: Bool {
        if layerEngine.physicallyHeldLayerID != nil { return true }
        return layerEngine.state != .base
    }

    private func resetTouchpadGesture() {
        touchpadFallbackEndTask?.cancel()
        touchpadFallbackEndTask = nil
        touchpadContactActive = false
        touchpadContactSuppressed = false
        touchpadRotor.end()
    }

    private func handleTouchpadMove(x: Float, source: String) {
        guard quickNavigation.isActive,
              !isActionLayerActiveForTouchpad,
              !touchpadContactSuppressed,
              let direction = touchpadRotor.move(x: x) else { return }
        let rotorOrder = mappings.activeProfile.quickNavigationOrder
        let change = direction > 0
            ? quickNavigation.nextCategoryChange(in: rotorOrder)
            : quickNavigation.previousCategoryChange(in: rotorOrder)
        if quickNavigation.category == .profiles {
            quickNavigation.synchronizeProfileSelection(
                profiles: mappings.profiles,
                activeProfileID: mappings.activeProfileID
            )
        }
        diagnostics.observe(
            source: .controller,
            result: "Touchpad: rotor threshold crossed via \(source)"
        )
        if settings.hapticFeedbackEnabled {
            controllerHaptics.play(change.wrapped ? .boundary : .selection)
        }
        announce(quickNavigation.currentSectionAnnouncement(
            quickBar: mappings.activeProfile.quickBar,
            profiles: mappings.profiles
        ))
    }

    private func detach(_ candidate: GCController) {
        guard candidate == controller else { return }
        releaseActiveActions()
        controller?.extendedGamepad?.valueChangedHandler = nil
        clearTouchpadHandlers()
        controller = nil
        connectedControllerName = nil
        controllerStatus = nil
        availableInputs = []
        controllerHasRemappedElements = false
    }

    private func process(element: GCControllerElement, gamepad: GCExtendedGamepad) {
        let now = ProcessInfo.processInfo.systemUptime
        refreshControllerStatus()
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
                // An armed Action Layer has priority over Quick Navigation.
                // Navigation is the default controller mode, but it must never
                // steal Cross/Circle/right-stick controls from a held or
                // one-shot layer. Once the layer returns to Base, Navigation
                // resumes without needing to be toggled back on.
                let action = resolvedAction(for: input)
                // A profile's remote Escape mapping must never be interpreted
                // as Circle's local "leave this mode" behavior. Resolve it
                // before the local-mode dispatcher so every press is routed
                // once to the original remote target and consumed here.
                if let action, action.sendsRemoteEscape {
                    diagnostics.observeController(
                        eventID: eventID,
                        input: input,
                        pressed: true,
                        stage: "Mapped remote Escape preempted local controller mode"
                    )
                    let started = start(action: action, input: input, eventID: eventID)
                    if started, let stateChange = layerEngine.consumeOneShotAfterResolvedAction() {
                        present(stateChange)
                    }
                    continue
                }
                if layerEngine.layerForAction() == nil,
                   handleModeInput(input, pressed: true, eventID: eventID) {
                    continue
                }
                guard let action else {
                    diagnostics.observeController(eventID: eventID, input: input, pressed: true, stage: "Binding lookup: no saved mapping")
                    continue
                }
                let started = start(action: action, input: input, eventID: eventID)
                if started {
                    switch action {
                    case .layer:
                        break
                    default:
                        if let stateChange = layerEngine.consumeOneShotAfterResolvedAction() {
                            present(stateChange)
                        }
                    }
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
        let layerID = layerEngine.layerForAction()
        guard let layerID else { return mappings.activeProfile.action(for: input) }

        // Once a modifier has been armed from a physically held Action Layer,
        // ordinary controls temporarily use Base mappings. Modifier controls
        // in that layer remain reachable so combinations such as Ctrl+Shift
        // can still be assembled without exposing Page Up/Page Down mappings
        // where the user expects plain arrow keys.
        if hasLayerScopedModifier(ownedBy: layerID) {
            let layeredAction = mappings.activeProfile.action(for: input, layerID: layerID)
            if case .stickyModifier? = layeredAction { return layeredAction }
            return mappings.activeProfile.action(for: input)
        }

        return mappings.activeProfile.action(for: input, layerID: layerID)
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
        case .stickyModifier(let sticky):
            return toggleStickyModifier(sticky, input: input, eventID: eventID)
        case .layer(let layer):
            present(layerEngine.press(layerID: layer.layerID, at: ProcessInfo.processInfo.systemUptime))
            return true
        case .quickNavigation:
            resetTouchpadGesture()
            let state = quickNavigation.toggle()
            if quickNavigation.isActive {
                quickNavigation.synchronizeProfileSelection(
                    profiles: mappings.profiles,
                    activeProfileID: mappings.activeProfileID
                )
                let section = quickNavigation.currentSectionAnnouncement(
                    quickBar: mappings.activeProfile.quickBar,
                    profiles: mappings.profiles
                )
                announce("Quick Navigation. \(section).")
            } else {
                announce(state)
            }
            return true
        case .farRelay(let farRelayAction):
            return performFarRelayAction(farRelayAction, input: input, eventID: eventID)
        }
    }

    /// Returns true if a local mode fully consumed the input.
    private func handleModeInput(_ input: ControllerInput, pressed: Bool, eventID: Int) -> Bool {
        if isQuickCommandModeActive {
            switch input {
            case .circle:
                setQuickCommandMode(false)
            default:
                diagnostics.observeController(eventID: eventID, input: input, pressed: pressed, stage: "Quick Command Mode: controller input gated")
            }
            return true
        }
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
                resetTouchpadGesture()
                announce(quickNavigation.exit() ?? "Quick Navigation off.")
            case .rightStickUp:
                switch quickNavigation.category {
                case .quickBar:
                    announce(quickNavigation.previousQuickBarAction(in: mappings.activeProfile.quickBar))
                case .profiles:
                    announce(quickNavigation.previousProfile(in: mappings.profiles))
                case .editing:
                    announce(quickNavigation.previousEditingAction())
                default:
                    if let key = quickNavigation.category.key {
                        start(
                            action: .keyboard(.init(key: key, modifiers: [.shift])),
                            input: input,
                            eventID: eventID
                        )
                    }
                }
            case .rightStickDown:
                switch quickNavigation.category {
                case .quickBar:
                    announce(quickNavigation.nextQuickBarAction(in: mappings.activeProfile.quickBar))
                case .profiles:
                    announce(quickNavigation.nextProfile(in: mappings.profiles))
                case .editing:
                    announce(quickNavigation.nextEditingAction())
                default:
                    if let key = quickNavigation.category.key {
                        start(action: .keyboard(.init(key: key)), input: input, eventID: eventID)
                    }
                }
            case .cross:
                switch quickNavigation.category {
                case .quickBar:
                    guard let entry = quickNavigation.selectedQuickBarEntry(in: mappings.activeProfile.quickBar),
                          let action = entry.action else {
                        announce("Quick Bar action is unassigned")
                        return true
                    }
                    _ = executeQuickBarAction(action, input: input, eventID: eventID, recordAsLast: true)
                case .profiles:
                    guard let profile = quickNavigation.selectedProfile(in: mappings.profiles) else {
                        announce("No profiles")
                        return true
                    }
                    if let name = mappings.activateProfile(id: profile.id) {
                        lastQuickBarAction = nil
                        if settings.hapticFeedbackEnabled { controllerHaptics.play(.boundary) }
                        announce("Profile: \(name)")
                    }
                case .editing:
                    start(
                        action: .keyboard(quickNavigation.selectedEditingAction().keyboardAction),
                        input: input,
                        eventID: eventID
                    )
                default:
                    start(action: .keyboard(.init(key: .enter)), input: input, eventID: eventID)
                }
            default:
                return false
            }
            return true
        }
        return false
    }

    @discardableResult
    private func executeQuickBarAction(
        _ action: ControllerAction,
        input: ControllerInput,
        eventID: Int,
        recordAsLast: Bool
    ) -> Bool {
        guard action.isAllowedInQuickBar else {
            diagnostics.observeController(
                eventID: eventID,
                input: input,
                pressed: true,
                stage: "Quick Bar: disallowed control action rejected"
            )
            announce("That action is not available in Quick Bar")
            return false
        }

        let started = start(action: action, input: input, eventID: eventID)
        if started, recordAsLast, action.isRepeatableQuickBarAction {
            lastQuickBarAction = action
        }
        return started
    }

    @discardableResult
    private func performFarRelayAction(
        _ action: FarRelayControllerAction,
        input: ControllerInput,
        eventID: Int
    ) -> Bool {
        switch action {
        case .textMode:
            setTextMode(!isTextModeActive)
            return true
        case .quickCommandMode:
            setQuickCommandMode(!isQuickCommandModeActive)
            return true
        case .repeatLastQuickBar:
            guard let lastQuickBarAction else {
                announce("No Quick Bar action to repeat")
                return true
            }
            return executeQuickBarAction(
                lastQuickBarAction,
                input: input,
                eventID: eventID,
                recordAsLast: false
            )
        case .nextProfile:
            if let name = mappings.activateNextProfile() {
                lastQuickBarAction = nil
                if settings.hapticFeedbackEnabled { controllerHaptics.play(.boundary) }
                announce("Profile: \(name)")
            }
            return true
        case .previousProfile:
            if let name = mappings.activatePreviousProfile() {
                lastQuickBarAction = nil
                if settings.hapticFeedbackEnabled { controllerHaptics.play(.boundary) }
                announce("Profile: \(name)")
            }
            return true
        }
    }

    @discardableResult
    private func toggleStickyModifier(
        _ action: ControllerStickyModifierAction,
        input: ControllerInput,
        eventID: Int
    ) -> Bool {
        guard action.isValid else {
            announce("Hold Modifier needs one to three modifiers")
            return false
        }

        let orderedModifiers = ControllerKeyboardModifier.allCases.filter {
            action.modifiers.contains($0)
        }

        let ownedLeases = orderedModifiers.compactMap {
            stickyModifierLeases[$0]
        }
        let ownedByThisInput = ownedLeases.count == orderedModifiers.count &&
            ownedLeases.allSatisfy { $0.ownerInput == input }

        // A modifier armed from a physically held Action Layer belongs to
        // that layer gesture. Re-activating the same action must never toggle
        // those modifiers off; it only repeats the optional tap key. The
        // layer release remains the single authoritative release boundary.
        if ownedByThisInput,
           let heldLayerID = layerEngine.physicallyHeldLayerID,
           ownedLeases.allSatisfy({ $0.ownerLayerID == heldLayerID }) {
            let held = heldModifierDescription(action.modifiers)
            if let tapKey = action.tapKey, let route = ownedLeases.first?.route {
                diagnostics.observeController(
                    eventID: eventID,
                    input: input,
                    pressed: true,
                    stage: "Sticky modifier: layer-owned repeat tap \(tapKey.label)"
                )
                Task { @MainActor [router] in
                    let key = RemoteKey.windowsVirtualKey(tapKey.virtualKey)
                    _ = await router.route(
                        .sendKeyTransition(key, pressed: true),
                        via: route
                    )
                    _ = await router.route(
                        .sendKeyTransition(key, pressed: false),
                        via: route
                    )
                }
                announce("\(held) still held. \(tapKey.label) tapped")
            } else {
                announce(
                    "\(held) remains held until \(heldLayerID.capitalized) layer is released"
                )
            }
            if settings.hapticFeedbackEnabled { controllerHaptics.play(.selection) }
            return true
        }

        if ownedByThisInput {
            let leases = orderedModifiers.compactMap {
                stickyModifierLeases.removeValue(forKey: $0)
            }
            routeStickyModifierLeases(
                leases,
                pressed: false,
                eventID: eventID,
                input: input
            )
            announce("\(heldModifierDescription(action.modifiers)) released")
            if settings.hapticFeedbackEnabled { controllerHaptics.play(.selection) }
            return true
        }
        guard orderedModifiers.allSatisfy({ stickyModifierLeases[$0] == nil }) else {
            announce("One of those modifiers is already held by another action")
            return false
        }

        guard let targetID = router.activeTargetID,
              let route = router.routeLease(for: targetID),
              let target = router.target(for: route),
              target.capabilities.contains(.rawKeyInput) else {
            diagnostics.observeController(
                eventID: eventID,
                input: input,
                pressed: true,
                stage: "Sticky modifier: raw key target unavailable; no fallback"
            )
            announce("Sticky modifier unavailable")
            return false
        }

        let resolved = orderedModifiers.map {
            ($0, stickyModifierVirtualKeys(for: $0))
        }
        let physicalKeys = resolved.flatMap { $0.1 }
        guard !physicalKeys.isEmpty,
              Set(physicalKeys).count == physicalKeys.count else {
            announce("Those held modifiers overlap on this NVDA modifier configuration")
            return false
        }

        if let tapKey = action.tapKey,
           physicalKeys.contains(tapKey.virtualKey) {
            announce("Tap key cannot also be one of the held modifier keys")
            return false
        }

        let ownerLayerID = layerEngine.physicallyHeldLayerID
        let leases = resolved.map { modifier, virtualKeys in
            StickyModifierLease(
                modifier: modifier,
                ownerInput: input,
                virtualKeys: virtualKeys,
                route: route,
                ownerLayerID: ownerLayerID
            )
        }
        for lease in leases {
            stickyModifierLeases[lease.modifier] = lease
        }

        routeStickyModifierActivation(
            leases,
            tapKey: action.tapKey,
            eventID: eventID,
            input: input
        )

        let held = heldModifierDescription(action.modifiers)
        if let ownerLayerID {
            announce("\(held) held until \(ownerLayerID.capitalized) layer is released")
        } else if let tapKey = action.tapKey {
            announce("\(held) held. \(tapKey.label) tapped")
        } else {
            announce("\(held) held")
        }
        if settings.hapticFeedbackEnabled { controllerHaptics.play(.selection) }
        return true
    }

    private func heldModifierDescription(
        _ modifiers: Set<ControllerKeyboardModifier>
    ) -> String {
        ControllerKeyboardModifier.allCases
            .filter { modifiers.contains($0) }
            .map(\.label)
            .joined(separator: " plus ")
    }

    private func routeStickyModifierActivation(
        _ leases: [StickyModifierLease],
        tapKey: WindowsKeyboardKey?,
        eventID: Int,
        input: ControllerInput
    ) {
        guard let route = leases.first?.route else { return }
        diagnostics.observeController(
            eventID: eventID,
            input: input,
            pressed: true,
            stage: "Sticky modifier: \(leases.count) held modifier(s) activated"
        )
        Task { @MainActor [router] in
            for lease in leases {
                for virtualKey in lease.virtualKeys {
                    _ = await router.route(
                        .sendKeyTransition(.windowsVirtualKey(virtualKey), pressed: true),
                        via: route
                    )
                }
            }
            if let tapKey {
                let key = RemoteKey.windowsVirtualKey(tapKey.virtualKey)
                _ = await router.route(.sendKeyTransition(key, pressed: true), via: route)
                _ = await router.route(.sendKeyTransition(key, pressed: false), via: route)
            }
        }
    }

    private func routeStickyModifierLeases(
        _ leases: [StickyModifierLease],
        pressed: Bool,
        eventID: Int,
        input: ControllerInput
    ) {
        guard !leases.isEmpty else { return }
        diagnostics.observeController(
            eventID: eventID,
            input: input,
            pressed: pressed,
            stage: "Sticky modifier: \(leases.count) held modifier(s) \(pressed ? "held" : "released")"
        )
        let orderedLeases = pressed ? leases : Array(leases.reversed())
        Task { @MainActor [router] in
            for lease in orderedLeases {
                let virtualKeys = pressed
                    ? lease.virtualKeys
                    : Array(lease.virtualKeys.reversed())
                for virtualKey in virtualKeys {
                    _ = await router.route(
                        .sendKeyTransition(.windowsVirtualKey(virtualKey), pressed: pressed),
                        via: lease.route
                    )
                }
            }
        }
    }

    private func stickyModifierVirtualKeys(for modifier: ControllerKeyboardModifier) -> [UInt16] {
        switch modifier {
        case .shift: [VK.shift]
        case .control: [VK.control]
        case .alt: [VK.menu]
        case .windows: [VK.lwin]
        case .nvda:
            switch settings.nvdaModifier {
            case .capsLock: [VK.capital]
            case .voKeys: [VK.control, VK.menu]
            }
        }
    }

    private func hasLayerScopedModifier(ownedBy layerID: String) -> Bool {
        stickyModifierLeases.values.contains { $0.ownerLayerID == layerID }
    }

    private func releaseStickyModifiers(ownedBy layerID: String) {
        let modifiers = ControllerKeyboardModifier.allCases.filter {
            stickyModifierLeases[$0]?.ownerLayerID == layerID
        }
        let leases = modifiers.compactMap {
            stickyModifierLeases.removeValue(forKey: $0)
        }
        routeStickyModifierLeases(
            leases,
            pressed: false,
            eventID: diagnosticEventID(),
            input: .home
        )
    }

    private func releaseStickyModifiers() {
        let leases = ControllerKeyboardModifier.allCases.compactMap {
            stickyModifierLeases.removeValue(forKey: $0)
        }
        routeStickyModifierLeases(
            leases,
            pressed: false,
            eventID: diagnosticEventID(),
            input: .home
        )
    }

    func suspendInputForInactiveContext() {
        releaseActiveActions()
    }

    private func layerControlAction(for input: ControllerInput) -> ControllerLayerAction? {
        guard case .layer(let layer)? = mappings.activeProfile.action(for: input) else { return nil }
        return layer
    }

    private func releaseLayerControl(_ input: ControllerInput) {
        guard let layer = layerControlAction(for: input) else { return }
        // A modifier armed while this physical Action Layer was down belongs
        // to that hold. Release it before leaving the layer so remote modifier
        // state can never outlive the gesture that created it.
        releaseStickyModifiers(ownedBy: layer.layerID)
        if let stateChange = layerEngine.release(layerID: layer.layerID, at: ProcessInfo.processInfo.systemUptime) {
            present(stateChange)
        }
    }

    private func setTextMode(_ active: Bool) {
        resetTouchpadGesture()
        if !active, !isTextModeActive { return }
        if active, isQuickCommandModeActive {
            setQuickCommandMode(false, restoreQuickNavigation: false, announceChange: false)
        }
        isTextModeActive = active
        textMirrorSession.reset()
        textModeBuffer = ""
        cancelTextOperations()
        if active {
            _ = quickNavigation.exit()
        } else {
            releaseActiveActions()
            _ = quickNavigation.activate()
        }
        announce(active ? "Text Mode" : "Text Mode off")
    }

    func exitTextMode() { setTextMode(false) }

    func submitTextModeAndExit() {
        guard isTextModeActive else { return }
        let previous = textOperationTail
        let generation = textOperationGeneration
        textOperationTail = Task { @MainActor [weak self, previous] in
            _ = await previous?.value
            guard let self,
                  generation == self.textOperationGeneration,
                  !Task.isCancelled,
                  self.isTextModeActive else { return }

            await self.routeTextTap(
                .init(key: .enter),
                diagnostic: "Text Mode: submit Enter transmitted"
            )
            guard generation == self.textOperationGeneration,
                  !Task.isCancelled,
                  self.isTextModeActive else { return }

            self.feedback.play(.success)
            self.setTextMode(false)
        }
    }

    private func setQuickCommandMode(
        _ active: Bool,
        restoreQuickNavigation: Bool = true,
        announceChange: Bool = true
    ) {
        resetTouchpadGesture()
        if active, isTextModeActive {
            setTextMode(false)
        }
        if !active, !isQuickCommandModeActive { return }
        isQuickCommandModeActive = active
        quickCommandBuffer = ""
        quickCommandStatus = nil
        preparedQuickCommand = nil
        cancelQuickCommand()
        if active {
            _ = quickNavigation.exit()
        } else if restoreQuickNavigation {
            releaseActiveActions(exitQuickNavigation: false)
            _ = quickNavigation.activate()
        }
        if announceChange {
            announce(active ? "Quick Command Mode" : "Quick Command Mode off")
        }
    }

    func exitQuickCommandMode() { setQuickCommandMode(false) }

    func updateQuickCommandBuffer(_ value: String) {
        guard isQuickCommandModeActive else { return }
        quickCommandBuffer = value
        quickCommandStatus = nil
        preparedQuickCommand = nil
    }

    /// Parses and fully validates the local buffer without sending any remote
    /// input. The returned text is exactly how FarRelay interpreted it and is
    /// intended for the confirmation alert.
    @discardableResult
    func prepareQuickCommandForConfirmation() -> String? {
        guard isQuickCommandModeActive else { return nil }

        let command: QuickCommand
        do {
            command = try QuickCommandParser.parse(quickCommandBuffer)
        } catch let error as QuickCommandParseError {
            quickCommandStatus = error.message
            diagnostics.observe(source: .controller, result: "Quick Command: parse rejected")
            announcePrivate(error.message)
            return nil
        } catch {
            quickCommandStatus = "Quick Command could not be parsed."
            diagnostics.observe(source: .controller, result: "Quick Command: parse rejected")
            announcePrivate("Quick Command could not be parsed.")
            return nil
        }

        guard let targetID = router.activeTargetID,
              let route = router.routeLease(for: targetID),
              let target = router.target(for: route),
              target.capabilities.contains(.rawKeyInput),
              target.kind == .nvdaRemote || target.kind == .macRemote else {
            quickCommandStatus = "Quick Command requires an active Windows/NVDA or Mac Remote keyboard target."
            diagnostics.observe(source: .controller, result: "Quick Command: raw keyboard target unavailable")
            announcePrivate(quickCommandStatus!)
            preparedQuickCommand = nil
            return nil
        }

        let plan: [[QuickCommandTransmission]]
        do {
            switch target.kind {
            case .nvdaRemote:
                plan = try resolveWindowsQuickCommandPlan(command)
            case .macRemote:
                plan = try resolveMacQuickCommandPlan(command)
            default:
                quickCommandStatus = "Quick Command is not available for this target."
                diagnostics.observe(source: .controller, result: "Quick Command: unsupported target")
                announcePrivate(quickCommandStatus!)
                preparedQuickCommand = nil
                return nil
            }
        } catch let error as QuickCommandExecutionError {
            quickCommandStatus = error.message
            diagnostics.observe(source: .controller, result: "Quick Command: target validation rejected")
            announcePrivate(error.message)
            preparedQuickCommand = nil
            return nil
        } catch {
            quickCommandStatus = "Quick Command is not available for this target."
            diagnostics.observe(source: .controller, result: "Quick Command: target validation rejected")
            announcePrivate(quickCommandStatus!)
            preparedQuickCommand = nil
            return nil
        }

        let preview = command.spokenDescription
        preparedQuickCommand = PreparedQuickCommand(
            command: command,
            preview: preview,
            plan: plan,
            route: route
        )
        quickCommandStatus = "Ready to confirm."
        diagnostics.observe(
            source: .controller,
            result: "Quick Command: confirmation prepared; payload redacted"
        )
        return preview
    }

    func cancelQuickCommandConfirmation() {
        preparedQuickCommand = nil
        if isQuickCommandModeActive, quickCommandStatus == "Ready to confirm." {
            quickCommandStatus = nil
        }
    }

    /// The alert's Send button is the only execution boundary.
    @discardableResult
    func confirmQuickCommand() -> Bool {
        guard isQuickCommandModeActive, let prepared = preparedQuickCommand else {
            return false
        }
        preparedQuickCommand = nil

        cancelQuickCommand()
        let generation = quickCommandGeneration
        diagnostics.observe(
            source: .controller,
            result: "Quick Command: confirmed \(prepared.command.steps.count) steps; payload redacted"
        )
        quickCommandStatus = "Sending command."
        quickCommandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.executeQuickCommandPlan(
                prepared.plan,
                via: prepared.route,
                generation: generation
            )
            guard generation == self.quickCommandGeneration, !Task.isCancelled else { return }
            switch result {
            case .performed:
                self.diagnostics.observe(source: .controller, result: "Quick Command: completed")
                self.releaseActiveActions(exitQuickNavigation: false)
                self.isQuickCommandModeActive = false
                self.quickCommandBuffer = ""
                self.preparedQuickCommand = nil
                self.quickCommandStatus = "Command sent."
                _ = self.quickNavigation.activate()
                self.feedback.play(.success)
                let section = self.quickNavigation.currentSectionAnnouncement(
                    quickBar: self.mappings.activeProfile.quickBar,
                    profiles: self.mappings.profiles
                )
                self.announce("Command sent. Quick Navigation. \(section).")
            case .unsupported:
                self.quickCommandStatus = "Quick Command is unsupported by the active target."
                self.diagnostics.observe(source: .controller, result: "Quick Command: executor unsupported")
                self.announcePrivate(self.quickCommandStatus!)
            case .unavailable:
                self.quickCommandStatus = "Quick Command target became unavailable."
                self.diagnostics.observe(source: .controller, result: "Quick Command: target unavailable")
                self.announcePrivate(self.quickCommandStatus!)
            case .failed:
                self.quickCommandStatus = "Quick Command failed."
                self.diagnostics.observe(source: .controller, result: "Quick Command: transport failed")
                self.announcePrivate(self.quickCommandStatus!)
            }
        }
        return true
    }

    func waitForQuickCommandForTesting() async {
        await quickCommandTask?.value
    }

    private func cancelQuickCommand() {
        quickCommandGeneration += 1
        quickCommandTask?.cancel()
        quickCommandTask = nil
    }

    private enum QuickCommandExecutionError: Error {
        case unsupportedModifier(String, target: String)
        case unsupportedKey(String, target: String)
        case unsupportedTextCharacter(target: String)
        case resolvedChordTooLarge

        var message: String {
            switch self {
            case .unsupportedModifier(let name, let target):
                "\(name) is not available for \(target) Quick Command."
            case .unsupportedKey(let name, let target):
                "\(name) is not available for \(target) Quick Command."
            case .unsupportedTextCharacter(let target):
                "\(target) Quick Command text contains a character that cannot be typed yet."
            case .resolvedChordTooLarge:
                "Quick Command resolves to more than four physical keys at once."
            }
        }
    }

    private enum QuickCommandTransmission {
        case chord([RemoteKey])
        case resolvedText(String)
    }

    private func resolveWindowsQuickCommandPlan(
        _ command: QuickCommand
    ) throws -> [[QuickCommandTransmission]] {
        var plan: [[QuickCommandTransmission]] = []
        for step in command.steps {
            switch step {
            case .chord(let chord):
                let virtualKeys = try resolveWindowsChord(chord)
                guard virtualKeys.count <= QuickCommandParser.maximumChordKeys else {
                    throw QuickCommandExecutionError.resolvedChordTooLarge
                }
                plan.append([.chord(virtualKeys.map(RemoteKey.windowsVirtualKey))])

            case .text(let text):
                // Text comes from iOS as Unicode, not as physical key usages.
                // Preserve it through the bridge's layout-independent text
                // path rather than reproducing it through the remote layout.
                plan.append([.resolvedText(text)])
            }
        }
        return plan
    }

    private func resolveWindowsChord(_ chord: QuickCommandChord) throws -> [UInt16] {
        var result: [UInt16] = []
        for key in chord.keys {
            switch key {
            case .modifier(let modifier):
                switch modifier {
                case .control: result.append(VK.control)
                case .shift: result.append(VK.shift)
                case .alt: result.append(VK.menu)
                case .windows: result.append(VK.lwin)
                case .nvda:
                    switch settings.nvdaModifier {
                    case .capsLock:
                        result.append(VK.capital)
                    case .voKeys:
                        result.append(contentsOf: [VK.control, VK.menu])
                    }
                case .command:
                    throw QuickCommandExecutionError.unsupportedModifier(
                        "Command",
                        target: "Windows/NVDA"
                    )
                case .option:
                    throw QuickCommandExecutionError.unsupportedModifier(
                        "Option",
                        target: "Windows/NVDA"
                    )
                }
            case .key(let key):
                result.append(contentsOf: try windowsVirtualKeys(for: key))
            }
        }
        // A shifted punctuation target contributes Shift itself. If the user
        // also wrote Shift explicitly, retain one physical Shift rather than
        // rejecting a valid chord or sending duplicate downs.
        return result.reduce(into: []) { unique, key in
            if !unique.contains(key) { unique.append(key) }
        }
    }

    private func windowsVirtualKeys(
        for modifiers: Set<ControllerKeyboardModifier>
    ) -> [UInt16] {
        let order: [ControllerKeyboardModifier] = [.control, .alt, .shift, .windows, .nvda]
        var result: [UInt16] = []
        for modifier in order where modifiers.contains(modifier) {
            result.append(contentsOf: stickyModifierVirtualKeys(for: modifier))
        }
        return result
    }

    private func windowsVirtualKeys(for key: QuickCommandKey) throws -> [UInt16] {
        switch key {
        case .function(let number):
            guard (1...24).contains(number) else {
                throw QuickCommandExecutionError.unsupportedKey(
                    "Function key",
                    target: "Windows/NVDA"
                )
            }
            return [0x70 + UInt16(number - 1)]
        case .character(let character):
            guard let action = ControllerTextCharacterMapper.action(for: character) else {
                throw QuickCommandExecutionError.unsupportedKey(
                    String(character),
                    target: "Windows/NVDA"
                )
            }
            return windowsVirtualKeys(for: action.modifiers) + [action.key.virtualKey]
        case .named(let named):
            let virtualKey: UInt16 = switch named {
            case .tab: WindowsKeyboardKey.tab.virtualKey
            case .enter: WindowsKeyboardKey.enter.virtualKey
            case .escape: WindowsKeyboardKey.escape.virtualKey
            case .space: WindowsKeyboardKey.space.virtualKey
            case .backspace: WindowsKeyboardKey.backspace.virtualKey
            case .delete: WindowsKeyboardKey.delete.virtualKey
            case .insert: WindowsKeyboardKey.insert.virtualKey
            case .home: WindowsKeyboardKey.home.virtualKey
            case .end: WindowsKeyboardKey.end.virtualKey
            case .pageUp: WindowsKeyboardKey.pageUp.virtualKey
            case .pageDown: WindowsKeyboardKey.pageDown.virtualKey
            case .left: WindowsKeyboardKey.left.virtualKey
            case .right: WindowsKeyboardKey.right.virtualKey
            case .up: WindowsKeyboardKey.up.virtualKey
            case .down: WindowsKeyboardKey.down.virtualKey
            case .capsLock: WindowsKeyboardKey.capsLock.virtualKey
            case .pause: WindowsKeyboardKey.pause.virtualKey
            case .printScreen: WindowsKeyboardKey.printScreen.virtualKey
            case .scrollLock: WindowsKeyboardKey.scrollLock.virtualKey
            case .numLock: WindowsKeyboardKey.numLock.virtualKey
            case .contextMenu: WindowsKeyboardKey.contextMenu.virtualKey
            case .comma: WindowsKeyboardKey.comma.virtualKey
            case .period: WindowsKeyboardKey.period.virtualKey
            case .slash: WindowsKeyboardKey.slash.virtualKey
            case .backslash: WindowsKeyboardKey.backslash.virtualKey
            case .semicolon: WindowsKeyboardKey.semicolon.virtualKey
            case .quote: WindowsKeyboardKey.quote.virtualKey
            case .grave: WindowsKeyboardKey.grave.virtualKey
            case .minus: WindowsKeyboardKey.minus.virtualKey
            case .equal: WindowsKeyboardKey.equal.virtualKey
            case .leftBracket: WindowsKeyboardKey.leftBracket.virtualKey
            case .rightBracket: WindowsKeyboardKey.rightBracket.virtualKey
            }
            return [virtualKey]
        }
    }

    private func resolveMacQuickCommandPlan(
        _ command: QuickCommand
    ) throws -> [[QuickCommandTransmission]] {
        var plan: [[QuickCommandTransmission]] = []
        for step in command.steps {
            switch step {
            case .chord(let chord):
                let usages = try resolveMacChord(chord)
                guard usages.count <= QuickCommandParser.maximumChordKeys else {
                    throw QuickCommandExecutionError.resolvedChordTooLarge
                }
                let keys = try usages.map { usage -> RemoteKey in
                    guard MacRemoteKey.supportedKeyboardUsage(usage) != nil,
                          let key = RemoteKey.hidUsage(usage) else {
                        throw QuickCommandExecutionError.unsupportedKey(
                            "Key",
                            target: "Mac"
                        )
                    }
                    return key
                }
                plan.append([.chord(keys)])

            case .text(let text):
                var textStep: [QuickCommandTransmission] = []
                textStep.reserveCapacity(text.count)
                for character in text {
                    guard let usages = macHIDChord(for: character) else {
                        throw QuickCommandExecutionError.unsupportedTextCharacter(
                            target: "Mac"
                        )
                    }
                    guard usages.count <= QuickCommandParser.maximumChordKeys else {
                        throw QuickCommandExecutionError.resolvedChordTooLarge
                    }
                    let keys = try usages.map { usage -> RemoteKey in
                        guard MacRemoteKey.supportedKeyboardUsage(usage) != nil,
                              let key = RemoteKey.hidUsage(usage) else {
                            throw QuickCommandExecutionError.unsupportedKey(
                                "Key",
                                target: "Mac"
                            )
                        }
                        return key
                    }
                    textStep.append(.chord(keys))
                }
                plan.append(textStep)
            }
        }
        return plan
    }

    private func resolveMacChord(_ chord: QuickCommandChord) throws -> [UInt16] {
        var result: [UInt16] = []
        for key in chord.keys {
            switch key {
            case .modifier(let modifier):
                switch modifier {
                case .control: result.append(0xE0)
                case .shift: result.append(0xE1)
                case .alt, .option: result.append(0xE2)
                case .command: result.append(0xE3)
                case .windows:
                    throw QuickCommandExecutionError.unsupportedModifier("Windows", target: "Mac")
                case .nvda:
                    throw QuickCommandExecutionError.unsupportedModifier("NVDA", target: "Mac")
                }
            case .key(let key):
                result.append(try macHIDUsage(for: key))
            }
        }
        guard Set(result).count == result.count else {
            throw QuickCommandExecutionError.unsupportedKey(
                "Duplicate resolved key",
                target: "Mac"
            )
        }
        return result
    }

    private func macHIDUsage(for key: QuickCommandKey) throws -> UInt16 {
        switch key {
        case .function(let number):
            guard (1...12).contains(number) else {
                throw QuickCommandExecutionError.unsupportedKey(
                    "F\(number)",
                    target: "Mac"
                )
            }
            return 0x3A + UInt16(number - 1)

        case .character(let character):
            let value = String(character).lowercased()
            guard value.unicodeScalars.count == 1,
                  let scalar = value.unicodeScalars.first else {
                throw QuickCommandExecutionError.unsupportedKey(
                    String(character),
                    target: "Mac"
                )
            }
            if (97...122).contains(scalar.value) {
                return 0x04 + UInt16(scalar.value - 97)
            }
            if (49...57).contains(scalar.value) {
                return 0x1E + UInt16(scalar.value - 49)
            }
            if scalar.value == 48 { return 0x27 }
            throw QuickCommandExecutionError.unsupportedKey(
                String(character),
                target: "Mac"
            )

        case .named(let named):
            let usage: UInt16? = switch named {
            case .tab: 0x2B
            case .enter: 0x28
            case .escape: 0x29
            case .space: 0x2C
            case .backspace: 0x2A
            case .delete: 0x4C
            case .insert: 0x49
            case .home: 0x4A
            case .end: 0x4D
            case .pageUp: 0x4B
            case .pageDown: 0x4E
            case .left: 0x50
            case .right: 0x4F
            case .up: 0x52
            case .down: 0x51
            case .capsLock: 0x39
            case .comma: 0x36
            case .period: 0x37
            case .slash: 0x38
            case .backslash: 0x31
            case .semicolon: 0x33
            case .quote: 0x34
            case .grave: 0x35
            case .minus: 0x2D
            case .equal: 0x2E
            case .leftBracket: 0x2F
            case .rightBracket: 0x30
            case .pause, .printScreen, .scrollLock, .numLock, .contextMenu: nil
            }
            guard let usage, MacRemoteKey.supportedKeyboardUsage(usage) != nil else {
                throw QuickCommandExecutionError.unsupportedKey(
                    named.spokenName,
                    target: "Mac"
                )
            }
            return usage
        }
    }

    private func macHIDChord(for character: Character) -> [UInt16]? {
        let value = String(character)
        guard value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first else {
            return nil
        }

        func shifted(_ usage: UInt16) -> [UInt16] { [0xE1, usage] }

        switch scalar.value {
        case 65...90: return shifted(0x04 + UInt16(scalar.value - 65))
        case 97...122: return [0x04 + UInt16(scalar.value - 97)]
        case 49...57: return [0x1E + UInt16(scalar.value - 49)]
        case 48: return [0x27]
        case 9: return [0x2B]
        case 10, 13: return [0x28]
        case 32: return [0x2C]
        case 33: return shifted(0x1E)
        case 34: return shifted(0x34)
        case 35: return shifted(0x20)
        case 36: return shifted(0x21)
        case 37: return shifted(0x22)
        case 38: return shifted(0x24)
        case 39: return [0x34]
        case 40: return shifted(0x26)
        case 41: return shifted(0x27)
        case 42: return shifted(0x25)
        case 43: return shifted(0x2E)
        case 44: return [0x36]
        case 45: return [0x2D]
        case 46: return [0x37]
        case 47: return [0x38]
        case 58: return shifted(0x33)
        case 59: return [0x33]
        case 60: return shifted(0x36)
        case 61: return [0x2E]
        case 62: return shifted(0x37)
        case 63: return shifted(0x38)
        case 64: return shifted(0x1F)
        case 91: return [0x2F]
        case 92: return [0x31]
        case 93: return [0x30]
        case 94: return shifted(0x23)
        case 95: return shifted(0x2D)
        case 96: return [0x35]
        case 123: return shifted(0x2F)
        case 124: return shifted(0x31)
        case 125: return shifted(0x30)
        case 126: return shifted(0x35)
        default: return nil
        }
    }

    private func executeQuickCommandPlan(
        _ plan: [[QuickCommandTransmission]],
        via route: RemoteIntentRoute,
        generation: Int
    ) async -> RemoteIntentResult {
        for (stepIndex, step) in plan.enumerated() {
            for transmission in step {
                guard generation == quickCommandGeneration,
                      !Task.isCancelled,
                      isQuickCommandModeActive else {
                    return .unavailable("Quick Command was cancelled.")
                }

                let chord: [RemoteKey]
                switch transmission {
                case .resolvedText(let text):
                    let result = await router.route(.sendText(text), via: route)
                    guard result == .performed else { return result }
                    continue
                case .chord(let resolvedChord):
                    chord = resolvedChord
                }

                var pressed: [RemoteKey] = []
                for key in chord {
                    guard generation == quickCommandGeneration,
                          !Task.isCancelled,
                          isQuickCommandModeActive else {
                        await releaseQuickCommandKeys(pressed, via: route)
                        return .unavailable("Quick Command was cancelled.")
                    }

                    pressed.append(key)
                    let result = await router.route(
                        .sendKeyTransition(key, pressed: true),
                        via: route
                    )
                    if result != .performed {
                        await releaseQuickCommandKeys(pressed, via: route)
                        return result
                    }
                }

                for key in pressed.reversed() {
                    let result = await router.route(
                        .sendKeyTransition(key, pressed: false),
                        via: route
                    )
                    if result != .performed {
                        return result
                    }
                }
            }

            if stepIndex < plan.count - 1 {
                do {
                    try await Task.sleep(
                        nanoseconds: QuickCommandExecutionPolicy.interStepDelayNanoseconds
                    )
                } catch {
                    return .unavailable("Quick Command was cancelled.")
                }
            }
        }
        return .performed
    }

    private func releaseQuickCommandKeys(
        _ keys: [RemoteKey],
        via route: RemoteIntentRoute
    ) async {
        for key in keys.reversed() {
            _ = await router.route(
                .sendKeyTransition(key, pressed: false),
                via: route
            )
        }
    }

    private func announcePrivate(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// Mirrors local BSI/editor deltas through the same router used by
    /// controller bindings. iOS has already resolved the text to Unicode, so
    /// it must not be converted back through a physical-key layout.
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
        guard !characters.isEmpty else { return }
        for character in characters { textMirrorSession.append(character, mirrored: true) }
        textModeBuffer = textMirrorSession.text
        enqueueTextInsertion(String(characters), diagnostic: "Text Mode: text transmitted")
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

    private func enqueueTextInsertion(_ text: String, diagnostic: String) {
        let previous = textOperationTail
        let generation = textOperationGeneration
        textOperationTail = Task { @MainActor [weak self, previous] in
            _ = await previous?.value
            guard let self, generation == self.textOperationGeneration, !Task.isCancelled else { return }
            await self.routeTextInsertion(text, diagnostic: diagnostic)
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

    private func routeTextInsertion(_ text: String, diagnostic: String) async {
        guard let targetID = router.activeTargetID else {
            diagnostics.observe(source: .controller, result: "\(diagnostic); no active target")
            return
        }
        diagnostics.observe(source: .controller, result: diagnostic)
        _ = await router.route(.sendText(text), to: targetID)
    }

    private func present(_ stateChange: LayerFeedback) {
        switch stateChange {
        case .activated, .oneShot:
            feedback.play(.selectionAccepted)
        case .locked:
            feedback.play(.success)
        case .base:
            feedback.play(.layerExit, haptic: .selectionAccepted)
        }
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

    func beginTouchpadSwipeForTesting(x: Float) {
        receiveTouchpadContact(.down, x: x, source: "test")
    }

    func moveTouchpadForTesting(x: Float) {
        guard touchpadContactActive else { return }
        receiveTouchpadContact(.moving, x: x, source: "test")
    }

    func endTouchpadSwipeForTesting() {
        receiveTouchpadContact(.up, x: 0, source: "test")
    }

    func receiveTouchpadContactForTesting(
        _ phase: ControllerTouchpadContactPhase,
        x: Float
    ) {
        receiveTouchpadContact(phase, x: x, source: "test")
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

    private func releaseActiveActions(exitQuickNavigation: Bool = true) {
        releaseStickyModifiers()
        let actions = ControllerInput.allCases.compactMap { input in
            activeActions[input].map { (input, $0) }
        }
        activeActions.removeAll()
        _ = inputLifecycle.releaseAll()
        leftStick.reset()
        rightStick.reset()
        resetTouchpadGesture()
        layerEngine.reset()
        if exitQuickNavigation { _ = quickNavigation.exit() }
        isTextModeActive = false
        textMirrorSession.reset()
        textModeBuffer = ""
        cancelTextOperations()
        isQuickCommandModeActive = false
        quickCommandBuffer = ""
        quickCommandStatus = nil
        preparedQuickCommand = nil
        cancelQuickCommand()
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
