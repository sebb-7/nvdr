import Foundation

/// VoiceOver Actions for one terminal session row.
enum TerminalSessionAccessibilityAction: String, Equatable, Hashable, Sendable {
    case open = "Open"
    case pin = "Pin Terminal"
    case unpin = "Unpin Terminal"
    case rename = "Rename Terminal"
    case retry = "Retry"
    case moveUp = "Move Up"
    case moveDown = "Move Down"
    case close = "Close Terminal"

    var name: String { rawValue }
}

struct TerminalSessionCapabilities: Equatable, Sendable {
    var canPin: Bool
    var canUnpin: Bool
    var canRename: Bool
    var canRetry: Bool
    var canMoveUp: Bool
    var canMoveDown: Bool
    var canClose: Bool
}

enum TerminalSessionActionPolicy {
    static func actions(for capabilities: TerminalSessionCapabilities) -> [TerminalSessionAccessibilityAction] {
        // The row itself is a Button, so normal activation already opens it.
        var actions: [TerminalSessionAccessibilityAction] = []
        if capabilities.canUnpin {
            actions.append(.unpin)
        } else if capabilities.canPin {
            actions.append(.pin)
        }
        if capabilities.canRename {
            actions.append(.rename)
        }
        if capabilities.canRetry {
            actions.append(.retry)
        }
        if capabilities.canMoveUp {
            actions.append(.moveUp)
        }
        if capabilities.canMoveDown {
            actions.append(.moveDown)
        }
        if capabilities.canClose {
            actions.append(.close)
        }
        return actions
    }
}

/// VoiceOver Actions for one saved computer row on Home.
enum HostProfileAccessibilityAction: String, Equatable, Hashable, Sendable {
    case newTerminal = "New Terminal"
    case nvdaRemote = "NVDA Remote"
    case edit = "Edit Computer"
    case delete = "Delete Computer"

    var name: String { rawValue }
}

enum HostProfileActionPolicy {
    static func actions(for profile: HostProfile) -> [HostProfileAccessibilityAction] {
        var actions: [HostProfileAccessibilityAction] = [.newTerminal]
        if profile.isNVDARemoteEnabled {
            actions.append(.nvdaRemote)
        }
        actions.append(contentsOf: [.edit, .delete])
        return actions
    }
}

struct ConnectionAnnouncement: Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

enum ConnectionAnnouncementPolicy {
    static func terminalAnnouncement(
        from old: SSHTerminalHostState,
        to new: SSHTerminalHostState,
        computerName: String
    ) -> String? {
        guard old != new else { return nil }
        switch new {
        case .connecting:
            return "Connecting to \(computerName)"
        case .connected:
            return "Connected to \(computerName)"
        case .ended:
            return "Terminal disconnected"
        case .failed(let message):
            return "Connection failed: \(RemoteLaunchDiagnostics.sanitizedReason(message))"
        case .idle, .closed:
            return nil
        }
    }

    static func nvdaAnnouncement(
        from old: BridgeClient.Status,
        to new: BridgeClient.Status,
        computerName: String
    ) -> String? {
        guard !isEquivalent(old, new) else { return nil }
        switch new {
        case .connecting:
            switch old {
            case .idle, .disconnected, .failed:
                return "Connecting to \(computerName)"
            default:
                return nil
            }
        case .ready:
            return "Connected to \(computerName)"
        case .nvdaNotConnected:
            return nil
        case .reconnecting:
            return nil
        case .failed:
            return "NVDA connection failed"
        case .authenticating, .idle, .disconnected:
            return nil
        }
    }

    static func isEquivalent(_ a: BridgeClient.Status, _ b: BridgeClient.Status) -> Bool {
        switch (a, b) {
        case (.reconnecting, .reconnecting),
             (.connecting, .connecting),
             (.authenticating, .authenticating),
             (.ready, .ready),
             (.nvdaNotConnected, .nvdaNotConnected),
             (.failed, .failed),
             (.idle, .idle):
            true
        case (.disconnected, .disconnected):
            true
        default:
            a == b
        }
    }
}

enum NVDAForwardingAnnouncementPolicy {
    static func announcement(forEnabled enabled: Bool) -> String {
        enabled ? "Remote keyboard forwarding on" : "Remote keyboard forwarding off"
    }
}
