import Foundation

@MainActor
protocol RemoteWindowsKeySink: AnyObject {
    var isInputForwardingReady: Bool { get }
    var activeProfileID: UUID? { get }
    func sendKey(vk: UInt16, pressed: Bool)
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
        case .reviewPrevious, .reviewNext, .returnToLive,
             .nextItem, .previousItem,
             .nextApplication, .previousApplication, .closeWindow, .showDesktop, .openStart,
             .sendChord:
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
    let remoteTargetID: RemoteTargetID
    let capabilities: Set<RemoteCapability> = [
        .genericNavigation,
        .applicationNavigation,
        .rawKeyInput,
        .rawChordInput
    ]

    private let keySink: any RemoteWindowsKeySink

    init(
        keySink: any RemoteWindowsKeySink,
        id: RemoteTargetID = RemoteTargetID("nvda")
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
            return .unavailable("NVDA input forwarding is unavailable.")
        }

        switch intent {
        case .nextItem:
            emitKey(VK.tab)
        case .previousItem:
            emitChord(modifiers: [.shift], key: VK.tab)
        case .activate:
            emitKey(VK.return)
        case .cancel:
            emitKey(VK.escape)
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
        case .reviewPrevious, .reviewNext, .returnToLive, .terminalInterrupt, .terminalEOF:
            return .unsupported
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
        return nil
    }
}

/// Keeps Mac Remote's controller lease and key-injection ownership in
/// `MacRemoteSession` while exposing only semantic actions to the router.
@MainActor
protocol MacRemoteIntentControlling: AnyObject {
    var activeProfile: HostProfile? { get }
    var remoteIntentConnectionState: HostTarget.ConnectionState { get }

    func performMacRemoteAction(_ action: MacRemoteAction) async -> RemoteIntentResult
}

@MainActor
final class MacRemoteIntentTarget: HostTargetExecutor {
    static let defaultID = RemoteTargetID("mac-remote")

    private let controller: any MacRemoteIntentControlling

    init(
        controller: any MacRemoteIntentControlling,
        id: RemoteTargetID = defaultID
    ) {
        self.controller = controller
        self.id = id
    }

    private let id: RemoteTargetID
    private let capabilities: Set<RemoteCapability> = [.macRemoteControl]

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
        guard case .macRemote(let action) = intent else { return .unsupported }
        return await controller.performMacRemoteAction(action)
    }
}

private extension RemoteModifier {
    static let emissionOrder: [RemoteModifier] = [.alt, .shift, .control, .commandOrWindows]

    var windowsVirtualKey: UInt16 {
        switch self {
        case .shift: VK.shift
        case .control: VK.control
        case .alt: VK.menu
        case .commandOrWindows: VK.lwin
        }
    }
}
