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
    private var lastQuickBarAction: ControllerAction?
    private var nextDiagnosticEventID = 1

    private(set) var isTextModeActive = false
    private(set) var textModeBuffer = ""
    var layerStateForTesting: ControllerLayerEngine.State { layerEngine.state }
    var isQuickNavigationActiveForTesting: Bool { quickNavigation.isActive }

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
            supportsHaptics: candidate.haptics != nil,
            supportsTouchpad: !candidate.physicalInputProfile.touchpads.isEmpty
        )
    }

    private func configureTouchpad(for candidate: GCController) {
        guard let touchpad = candidate.physicalInputProfile.touchpads.values.first else { return }
        self.touchpad = touchpad
        touchpad.touchDown = { [weak self] _, x, _, _, _ in
            Task { @MainActor in self?.touchpadRotor.begin(x: x) }
        }
        touchpad.touchMoved = { [weak self] _, x, _, _, _ in
            Task { @MainActor in self?.handleTouchpadMove(x: x) }
        }
        touchpad.touchUp = { [weak self] _, _, _, _, _ in
            Task { @MainActor in self?.touchpadRotor.end() }
        }
    }

    private func clearTouchpadHandlers() {
        touchpad?.touchDown = nil
        touchpad?.touchMoved = nil
        touchpad?.touchUp = nil
        touchpad = nil
        touchpadRotor.end()
    }

    private func handleTouchpadMove(x: Float) {
        guard quickNavigation.isActive, let direction = touchpadRotor.move(x: x) else { return }
        let change = direction > 0
            ? quickNavigation.nextCategoryChange()
            : quickNavigation.previousCategoryChange()
        if quickNavigation.category == .profiles {
            quickNavigation.synchronizeProfileSelection(
                profiles: mappings.profiles,
                activeProfileID: mappings.activeProfileID
            )
        }
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
                if handleModeInput(input, pressed: true, eventID: eventID) { continue }
                guard let action = resolvedAction(for: input) else {
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
            return toggleStickyModifier(sticky.modifier, input: input, eventID: eventID)
        case .layer(let layer):
            present(layerEngine.press(layerID: layer.layerID, at: ProcessInfo.processInfo.systemUptime))
            return true
        case .quickNavigation:
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
            case .rightStickUp:
                switch quickNavigation.category {
                case .quickBar:
                    announce(quickNavigation.previousQuickBarAction(in: mappings.activeProfile.quickBar))
                case .profiles:
                    announce(quickNavigation.previousProfile(in: mappings.profiles))
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
        _ modifier: ControllerKeyboardModifier,
        input: ControllerInput,
        eventID: Int
    ) -> Bool {
        if let lease = stickyModifierLeases.removeValue(forKey: modifier) {
            routeStickyModifier(lease, pressed: false, eventID: eventID, input: input)
            announce("\(modifier.label) released")
            if settings.hapticFeedbackEnabled { controllerHaptics.play(.selection) }
            return true
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

        let virtualKeys = stickyModifierVirtualKeys(for: modifier)
        guard !virtualKeys.isEmpty else { return false }
        let ownerLayerID = layerEngine.physicallyHeldLayerID
        let lease = StickyModifierLease(
            modifier: modifier,
            virtualKeys: virtualKeys,
            route: route,
            ownerLayerID: ownerLayerID
        )
        stickyModifierLeases[modifier] = lease
        routeStickyModifier(lease, pressed: true, eventID: eventID, input: input)
        if let ownerLayerID {
            announce("\(modifier.label) held until \(ownerLayerID.capitalized) layer is released")
        } else {
            announce("\(modifier.label) held")
        }
        if settings.hapticFeedbackEnabled { controllerHaptics.play(.selection) }
        return true
    }

    private func routeStickyModifier(
        _ lease: StickyModifierLease,
        pressed: Bool,
        eventID: Int,
        input: ControllerInput
    ) {
        let virtualKeys = pressed ? lease.virtualKeys : Array(lease.virtualKeys.reversed())
        diagnostics.observeController(
            eventID: eventID,
            input: input,
            pressed: pressed,
            stage: "Sticky modifier: \(lease.modifier.label) \(pressed ? "held" : "released")"
        )
        Task { @MainActor [router, route = lease.route] in
            for virtualKey in virtualKeys {
                _ = await router.route(
                    .sendKeyTransition(.windowsVirtualKey(virtualKey), pressed: pressed),
                    via: route
                )
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
        let leases = modifiers.compactMap { modifier -> StickyModifierLease? in
            stickyModifierLeases.removeValue(forKey: modifier)
        }
        for lease in leases.reversed() {
            routeStickyModifier(
                lease,
                pressed: false,
                eventID: diagnosticEventID(),
                input: .home
            )
        }
    }

    private func releaseStickyModifiers() {
        let leases = ControllerKeyboardModifier.allCases.compactMap { stickyModifierLeases[$0] }
        stickyModifierLeases.removeAll()
        for lease in leases.reversed() {
            routeStickyModifier(
                lease,
                pressed: false,
                eventID: diagnosticEventID(),
                input: .home
            )
        }
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

    func beginTouchpadSwipeForTesting(x: Float) {
        touchpadRotor.begin(x: x)
    }

    func moveTouchpadForTesting(x: Float) {
        handleTouchpadMove(x: x)
    }

    func endTouchpadSwipeForTesting() {
        touchpadRotor.end()
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
        releaseStickyModifiers()
        let actions = ControllerInput.allCases.compactMap { input in
            activeActions[input].map { (input, $0) }
        }
        activeActions.removeAll()
        _ = inputLifecycle.releaseAll()
        leftStick.reset()
        rightStick.reset()
        touchpadRotor.end()
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
