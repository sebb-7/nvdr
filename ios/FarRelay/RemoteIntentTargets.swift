import Foundation

@MainActor
protocol RemoteWindowsKeySink: AnyObject {
    /// Readiness of the remote command channel. It intentionally excludes the
    /// local responder's Forward Keyboard preference: semantic inputs (such
    /// as a controller) have their own source and must not be gated by it.
    var isInputForwardingReady: Bool { get }
    var activeProfileID: UUID? { get }
    /// Changes whenever the bridge replaces its IPC command channel. Held
    /// controller state must never cross this transport boundary.
    var inputSessionID: UUID? { get }
    var lastInputForwardingResult: InputForwardingResult? { get }
    func sendKey(vk: UInt16, pressed: Bool)
    func sendText(_ text: String)
}

/// Text transport was added after raw-key transport. Targets which only
/// understand keys remain source-compatible and report the text intent as
/// unsupported; the NVDA bridge provides the concrete implementation.
extension RemoteWindowsKeySink {
    func sendText(_ text: String) {}
}

extension BridgeClient: RemoteWindowsKeySink {}

/// Translates semantic intent into existing terminal presentation controls.
/// Presentation is resolved at perform-time so a hidden or arbitrary session
/// is never targeted. Future controller bindings should select a
/// `TerminalSession` ID rather than a list position.
@MainActor
final class TerminalRemoteIntentTarget: HostTargetExecutor {
    let remoteTargetID: RemoteTargetID
    let capabilities: Set<RemoteCapability> = [
        .genericNavigation,
        .terminalControl,
        .rawKeyInput
    ]

    private let resolvePresentation: @MainActor () -> TerminalPresentationModel?
    private let resolveProfile: @MainActor () -> HostProfile?
    private let resolveSessionID: @MainActor () -> UUID?

    init(
        presentation: TerminalPresentationModel,
        id: RemoteTargetID = RemoteTargetID("ssh-terminal")
    ) {
        self.resolvePresentation = { presentation }
        resolveProfile = { nil }
        resolveSessionID = { nil }
        remoteTargetID = id
    }

    init(
        manager: TerminalSessionManager,
        id: RemoteTargetID = RemoteTargetID("ssh-terminal")
    ) {
        self.resolvePresentation = { manager.currentTerminalPresentation }
        resolveProfile = {
            guard let id = manager.presentedSessionID else { return nil }
            return manager.session(id: id)?.profileSnapshot
        }
        resolveSessionID = { manager.presentedSessionID }
        remoteTargetID = id
    }

    var target: HostTarget {
        let presentation = resolvePresentation()
        let state: HostTarget.ConnectionState
        if presentation == nil {
            state = .disconnected
        } else if presentation?.sessionState == .connected {
            state = .ready
        } else {
            state = .unavailable("The SSH terminal is not connected.")
        }
        let profile = resolveProfile()
        return HostTarget(
            id: remoteTargetID,
            displayName: profile?.displayName ?? "SSH terminal",
            profileID: profile?.id,
            sessionID: resolveSessionID(),
            platform: profile?.platform ?? .other,
            kind: .sshTerminal,
            connectionState: state,
            capabilities: capabilities
        )
    }

    func perform(_ intent: RemoteIntent) async -> RemoteIntentResult {
        guard capabilities.contains(intent.requiredCapability) else { return .unsupported }
        guard let presentation = resolvePresentation() else {
            return .unavailable("No SSH terminal is currently active.")
        }
        guard presentation.sessionState == .connected else {
            return .unavailable("The SSH terminal is not connected.")
        }

        switch intent {
        case .nextItem:
            return await send(defaultControlID: "terminal.tab", using: presentation)
        case .previousItem:
            return await send(defaultControlID: "terminal.shift-tab", using: presentation)
        case .terminalInterrupt:
            return await send(defaultControlID: "terminal.interrupt", using: presentation)
        case .terminalEOF:
            return await send(defaultControlID: "terminal.eof", using: presentation)
        case .activate:
            return await send(defaultControlID: "terminal.return", using: presentation)
        case .cancel:
            return await send(defaultControlID: "terminal.escape", using: presentation)
        case .sendKey(let key):
            guard let controlID = terminalControlID(for: key) else { return .unsupported }
            return await send(defaultControlID: controlID, using: presentation)
        case .sendText,
             .reviewPrevious, .reviewNext, .returnToLive,
             .accessibilityNext, .accessibilityPrevious, .accessibilityActivate,
             .recovery,
             .nextApplication, .previousApplication, .closeWindow, .showDesktop, .openStart,
             .sendChord, .sendKeyTransition, .sendChordTransition,
             .repeatKey, .repeatChord, .macRemote:
            return .unsupported
        }
    }

    private func send(
        defaultControlID: String,
        using presentation: TerminalPresentationModel
    ) async -> RemoteIntentResult {
        guard let control = TerminalControlKey.defaultControl(id: defaultControlID) else {
            return .failed("The terminal control is unavailable.")
        }
        await presentation.send(control: control)
        return presentation.lastInputError == nil
            ? .performed
            : .failed("The terminal command could not be sent.")
    }

    private func terminalControlID(for key: RemoteKey) -> String? {
        guard let namedKey = key.namedKey else { return nil }
        return switch namedKey {
        case .tab: "terminal.tab"
        case .returnKey: "terminal.return"
        case .escape: "terminal.escape"
        case .backspace: "terminal.backspace"
        case .leftArrow: "terminal.left-arrow"
        case .rightArrow: "terminal.right-arrow"
        case .upArrow: "terminal.up-arrow"
        case .downArrow: "terminal.down-arrow"
        }
    }
}

/// Translates semantic intent into the bridge's existing Windows key events.
@MainActor
final class NVDARemoteIntentTarget: HostTargetExecutor {
    static let defaultID = RemoteTargetID("nvda")

    let remoteTargetID: RemoteTargetID
    let capabilities: Set<RemoteCapability> = [
        .genericNavigation,
        .accessibilityNavigation,
        .applicationSwitching,
        .applicationNavigation,
        .rawKeyInput,
        .rawChordInput,
        .textInput
    ]

    private let keySink: any RemoteWindowsKeySink
    private var heldVirtualKeys: [UInt16: Int] = [:]
    private var heldInputSessionID: UUID?

    init(
        keySink: any RemoteWindowsKeySink,
        id: RemoteTargetID = defaultID
    ) {
        self.keySink = keySink
        remoteTargetID = id
    }

    var target: HostTarget {
        HostTarget(
            id: remoteTargetID,
            displayName: "NVDA Remote",
            profileID: keySink.activeProfileID,
            sessionID: nil,
            platform: .windows,
            kind: .nvdaRemote,
            connectionState: keySink.isInputForwardingReady
                ? .ready
                : .unavailable("NVDA input forwarding is unavailable."),
            capabilities: capabilities
        )
    }

    func perform(_ intent: RemoteIntent) async -> RemoteIntentResult {
        guard capabilities.contains(intent.requiredCapability) else { return .unsupported }
        guard keySink.isInputForwardingReady else {
            heldVirtualKeys.removeAll()
            heldInputSessionID = nil
            return .unavailable("NVDA input forwarding is unavailable.")
        }
        synchronizeHeldInputSession()

        switch intent {
        case .nextItem:
            emitKey(VK.tab)
        case .previousItem:
            emitChord(modifiers: [.shift], key: VK.tab)
        case .activate:
            emitKey(VK.return)
        case .cancel:
            emitKey(VK.escape)
        case .accessibilityNext:
            // Until the bridge grows NVDA-native semantic operations, use the
            // established focus traversal shim rather than guessing object
            // navigation and changing proven controller behavior.
            emitKey(VK.tab)
        case .accessibilityPrevious:
            emitChord(modifiers: [.shift], key: VK.tab)
        case .accessibilityActivate:
            emitKey(VK.return)
        case .nextApplication:
            emitChord(modifiers: [.alt], key: VK.tab)
        case .previousApplication:
            emitChord(modifiers: [.alt, .shift], key: VK.tab)
        case .closeWindow:
            emitChord(modifiers: [.alt], key: VK.f1 + 3)
        case .showDesktop:
            emitChord(modifiers: [.commandOrWindows], key: 0x44)
        case .openStart:
            emitKey(VK.lwin)
        case .sendKey(let key):
            guard let key = windowsVirtualKey(for: key) else { return .unsupported }
            emitKey(key)
        case .sendChord(let chord):
            guard let key = windowsVirtualKey(for: chord.key) else { return .unsupported }
            emitChord(modifiers: chord.modifiers, key: key)
        case .sendText(let text):
            keySink.sendText(text)
        case .sendKeyTransition(let key, let pressed):
            guard let key = windowsVirtualKey(for: key) else { return .unsupported }
            transition(key, pressed: pressed)
        case .sendChordTransition(let chord, let pressed):
            guard let key = windowsVirtualKey(for: chord.key) else { return .unsupported }
            transition(chord: chord, key: key, pressed: pressed)
        case .repeatKey(let key):
            guard let key = windowsVirtualKey(for: key), heldVirtualKeys[key, default: 0] > 0 else { return .unsupported }
            keySink.sendKey(vk: key, pressed: true)
        case .repeatChord(let chord):
            guard let key = windowsVirtualKey(for: chord.key), heldVirtualKeys[key, default: 0] > 0 else { return .unsupported }
            keySink.sendKey(vk: key, pressed: true)
        case .reviewPrevious, .reviewNext, .returnToLive, .terminalInterrupt, .terminalEOF,
             .macRemote, .recovery:
            return .unsupported
        }
        if case .some(.rejected(let reason)) = keySink.lastInputForwardingResult {
            return .failed("NVDA transport rejected the key: \(reason)")
        }
        return .performed
    }

    private func emitKey(_ key: UInt16) {
        keySink.sendKey(vk: key, pressed: true)
        keySink.sendKey(vk: key, pressed: false)
    }

    private func emitChord(modifiers: Set<RemoteModifier>, key: UInt16) {
        let orderedModifiers = RemoteModifier.emissionOrder.filter { modifiers.contains($0) }
        for modifier in orderedModifiers {
            keySink.sendKey(vk: modifier.windowsVirtualKey, pressed: true)
        }
        keySink.sendKey(vk: key, pressed: true)
        keySink.sendKey(vk: key, pressed: false)
        for modifier in orderedModifiers.reversed() {
            keySink.sendKey(vk: modifier.windowsVirtualKey, pressed: false)
        }
    }

    private func transition(_ key: UInt16, pressed: Bool) {
        if pressed {
            retain(key)
        } else {
            release(key)
        }
    }

    private func synchronizeHeldInputSession() {
        let currentID = keySink.inputSessionID
        guard currentID != heldInputSessionID else { return }
        // BridgeClient has already issued protocol-level release_all before
        // replacing a channel. Discard only local ownership here; never send
        // a release into the new channel for a key it did not receive.
        heldVirtualKeys.removeAll()
        heldInputSessionID = currentID
    }

    private func transition(chord: RemoteChord, key: UInt16, pressed: Bool) {
        let modifiers = RemoteModifier.emissionOrder.filter { chord.modifiers.contains($0) }
        if pressed {
            modifiers.forEach { retain($0.windowsVirtualKey) }
            retain(key)
        } else {
            release(key)
            modifiers.reversed().forEach { release($0.windowsVirtualKey) }
        }
    }

    private func retain(_ key: UInt16) {
        let count = heldVirtualKeys[key, default: 0]
        heldVirtualKeys[key] = count + 1
        if count == 0 { keySink.sendKey(vk: key, pressed: true) }
    }

    private func release(_ key: UInt16) {
        guard let count = heldVirtualKeys[key], count > 0 else { return }
        if count == 1 {
            heldVirtualKeys[key] = nil
            keySink.sendKey(vk: key, pressed: false)
        } else {
            heldVirtualKeys[key] = count - 1
        }
    }

    private func windowsVirtualKey(for key: RemoteKey) -> UInt16? {
        if let namedKey = key.namedKey {
            switch namedKey {
            case .tab: return VK.tab
            case .returnKey: return VK.return
            case .escape: return VK.escape
            case .backspace: return VK.back
            case .leftArrow: return VK.left
            case .rightArrow: return VK.right
            case .upArrow: return VK.up
            case .downArrow: return VK.down
            }
        }
        if let number = key.functionNumber {
            // The existing Windows key layer handles F13 through F24 from
            // physical keyboard events. Raw semantic fallback stays limited
            // to the broadly useful F1 through F12 subset for now.
            guard (1...12).contains(number) else { return nil }
            return VK.f1 + UInt16(number - 1)
        }
        if let character = key.letterCharacter {
            let scalars = String(character).uppercased().unicodeScalars
            guard let scalar = scalars.first, (65...90).contains(scalar.value) else { return nil }
            return UInt16(scalar.value)
        }
        if let virtualKey = key.windowsVirtualKey { return virtualKey }
        return nil
    }
}

/// Keeps Mac Remote's controller lease and key-injection ownership in
/// `MacRemoteSession` while exposing semantic and validated raw-key input to
/// the same RemoteIntent router used by every other input source.
@MainActor
protocol MacRemoteIntentControlling: AnyObject {
    var activeProfile: HostProfile? { get }
    var remoteIntentConnectionState: HostTarget.ConnectionState { get }
    var remoteIntentGeneration: UInt64? { get }

    func performMacRemoteAction(_ action: MacRemoteAction) async -> RemoteIntentResult
    func performMacRemoteKeyTransition(
        _ key: MacRemoteKey,
        pressed: Bool
    ) async -> RemoteIntentResult
}

@MainActor
final class MacRemoteIntentTarget: HostTargetExecutor {
    static let defaultID = RemoteTargetID("mac-remote")

    private let controller: any MacRemoteIntentControlling
    private var heldKeys: [MacRemoteKey: Int] = [:]
    private var heldGeneration: UInt64?

    init(
        controller: any MacRemoteIntentControlling,
        id: RemoteTargetID = defaultID
    ) {
        self.controller = controller
        self.id = id
    }

    private let id: RemoteTargetID
    private let capabilities: Set<RemoteCapability> = [
        .accessibilityNavigation,
        .applicationSwitching,
        .rawKeyInput,
        .rawChordInput,
        .macRemoteControl
    ]

    var target: HostTarget {
        let profile = controller.activeProfile
        return HostTarget(
            id: id,
            displayName: profile?.displayName ?? "Mac Remote",
            profileID: profile?.id,
            sessionID: nil,
            platform: .macOS,
            kind: .macRemote,
            connectionState: controller.remoteIntentConnectionState,
            capabilities: capabilities
        )
    }

    func perform(_ intent: RemoteIntent) async -> RemoteIntentResult {
        guard capabilities.contains(intent.requiredCapability) else { return .unsupported }
        synchronizeHeldGeneration()

        switch intent {
        case .accessibilityNext:
            return await controller.performMacRemoteAction(.nextItem)
        case .accessibilityPrevious:
            return await controller.performMacRemoteAction(.previousItem)
        case .accessibilityActivate:
            return await controller.performMacRemoteAction(.activate)
        case .nextApplication:
            return await controller.performMacRemoteAction(.nextApplication)
        case .macRemote(let legacyAction):
            return await controller.performMacRemoteAction(legacyAction)

        case .sendKey(let key):
            guard let key = macKey(for: key) else { return .unsupported }
            return await tap([key])

        case .sendChord(let chord):
            guard let keys = macKeys(for: chord) else { return .unsupported }
            return await tap(keys)

        case .sendText:
            return .unsupported

        case .sendKeyTransition(let key, let pressed):
            guard let key = macKey(for: key) else { return .unsupported }
            return await transition([key], pressed: pressed)

        case .sendChordTransition(let chord, let pressed):
            guard let keys = macKeys(for: chord) else { return .unsupported }
            return await transition(keys, pressed: pressed)

        case .repeatKey(let key):
            guard let key = macKey(for: key), heldKeys[key, default: 0] > 0 else {
                return .unsupported
            }
            return await controller.performMacRemoteKeyTransition(key, pressed: true)

        case .repeatChord(let chord):
            guard let keys = macKeys(for: chord),
                  let key = keys.last,
                  heldKeys[key, default: 0] > 0 else {
                return .unsupported
            }
            return await controller.performMacRemoteKeyTransition(key, pressed: true)

        default:
            return .unsupported
        }
    }

    private func synchronizeHeldGeneration() {
        let current = controller.remoteIntentGeneration
        guard current != heldGeneration else { return }
        heldKeys.removeAll()
        heldGeneration = current
    }

    private func tap(_ keys: [MacRemoteKey]) async -> RemoteIntentResult {
        let down = await transition(keys, pressed: true)
        guard down == .performed else { return down }
        return await transition(keys, pressed: false)
    }

    private func transition(
        _ keys: [MacRemoteKey],
        pressed: Bool
    ) async -> RemoteIntentResult {
        if pressed {
            var retained: [MacRemoteKey] = []
            for key in keys {
                let result = await retain(key)
                guard result == .performed else {
                    for retainedKey in retained.reversed() {
                        _ = await release(retainedKey)
                    }
                    return result
                }
                retained.append(key)
            }
            return .performed
        }

        for key in keys.reversed() {
            let result = await release(key)
            guard result == .performed else { return result }
        }
        return .performed
    }

    private func retain(_ key: MacRemoteKey) async -> RemoteIntentResult {
        let count = heldKeys[key, default: 0]
        if count > 0 {
            heldKeys[key] = count + 1
            return .performed
        }

        let result = await controller.performMacRemoteKeyTransition(key, pressed: true)
        if result == .performed {
            heldKeys[key] = 1
        } else {
            heldKeys.removeAll()
            heldGeneration = controller.remoteIntentGeneration
        }
        return result
    }

    private func release(_ key: MacRemoteKey) async -> RemoteIntentResult {
        guard let count = heldKeys[key], count > 0 else {
            return .performed
        }
        if count > 1 {
            heldKeys[key] = count - 1
            return .performed
        }

        let result = await controller.performMacRemoteKeyTransition(key, pressed: false)
        if result == .performed {
            heldKeys[key] = nil
        } else {
            heldKeys.removeAll()
            heldGeneration = controller.remoteIntentGeneration
        }
        return result
    }

    private func macKeys(for chord: RemoteChord) -> [MacRemoteKey]? {
        let modifierOrder: [RemoteModifier] = [.control, .alt, .shift, .commandOrWindows]
        var keys: [MacRemoteKey] = []
        for modifier in modifierOrder where chord.modifiers.contains(modifier) {
            guard let key = macKey(for: modifier) else { return nil }
            keys.append(key)
        }
        if chord.modifiers.contains(.capsLock) { return nil }
        guard let primary = macKey(for: chord.key) else { return nil }
        keys.append(primary)
        return keys
    }

    private func macKey(for modifier: RemoteModifier) -> MacRemoteKey? {
        switch modifier {
        case .control: .leftControl
        case .shift: .leftShift
        case .alt: .leftOption
        case .commandOrWindows: .leftCommand
        case .capsLock: nil
        }
    }

    private func macKey(for key: RemoteKey) -> MacRemoteKey? {
        if let usage = key.usbHIDUsage {
            return MacRemoteKey.supportedKeyboardUsage(usage)
        }
        if let named = key.namedKey {
            let usage: UInt16 = switch named {
            case .tab: 0x2B
            case .returnKey: 0x28
            case .escape: 0x29
            case .backspace: 0x2A
            case .leftArrow: 0x50
            case .rightArrow: 0x4F
            case .upArrow: 0x52
            case .downArrow: 0x51
            }
            return MacRemoteKey.supportedKeyboardUsage(usage)
        }
        if let number = key.functionNumber {
            guard (1...12).contains(number) else { return nil }
            return MacRemoteKey.supportedKeyboardUsage(0x3A + UInt16(number - 1))
        }
        if let character = key.letterCharacter {
            let scalars = String(character).lowercased().unicodeScalars
            guard scalars.count == 1, let scalar = scalars.first,
                  (97...122).contains(scalar.value) else { return nil }
            return MacRemoteKey.supportedKeyboardUsage(0x04 + UInt16(scalar.value - 97))
        }
        return nil
    }
}

/// Keeps recovery host-scoped and independently selectable from an unavailable
/// screen-reader interaction target. macOS/Linux are represented by the same
/// target abstraction but advertise no recovery capability until implemented.
@MainActor
protocol HostRecoveryIntentControlling: AnyObject {
    var recoveryProfile: HostProfile? { get }
    var recoveryConnectionState: HostTarget.ConnectionState { get }
    var supportsAccessibilityRecovery: Bool { get }
    func restartAccessibility() async -> RemoteIntentResult
}

@MainActor
final class HostRecoveryIntentTarget: HostTargetExecutor {
    static func id(for profile: HostProfile) -> RemoteTargetID {
        RemoteTargetID("host-recovery-\(profile.id.uuidString.lowercased())")
    }

    private let controller: any HostRecoveryIntentControlling
    private let id: RemoteTargetID

    init(controller: any HostRecoveryIntentControlling, id: RemoteTargetID) {
        self.controller = controller
        self.id = id
    }

    var target: HostTarget {
        let profile = controller.recoveryProfile
        return HostTarget(
            id: id,
            displayName: profile.map { "\($0.displayName) recovery" } ?? "Host recovery",
            profileID: profile?.id,
            sessionID: nil,
            platform: profile?.platform ?? .other,
            kind: .hostRecovery,
            connectionState: controller.recoveryConnectionState,
            capabilities: controller.supportsAccessibilityRecovery ? [.hostRecovery] : []
        )
    }

    func perform(_ intent: RemoteIntent) async -> RemoteIntentResult {
        guard case .recovery(.restartAccessibility) = intent else { return .unsupported }
        guard controller.supportsAccessibilityRecovery else { return .unsupported }
        return await controller.restartAccessibility()
    }
}

private extension RemoteModifier {
    static let emissionOrder: [RemoteModifier] = [.alt, .shift, .control, .commandOrWindows, .capsLock]

    var windowsVirtualKey: UInt16 {
        switch self {
        case .shift: VK.shift
        case .control: VK.control
        case .alt: VK.menu
        case .commandOrWindows: VK.lwin
        case .capsLock: VK.capital
        }
    }
}
