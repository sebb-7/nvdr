import Foundation
import Observation

/// One application-level live terminal. Identity is a stable UUID, not a title,
/// host name, or list position. The captured profile snapshot keeps the session
/// identifiable if the saved HostProfile is later renamed or deleted.
@Observable
@MainActor
final class TerminalSession: Identifiable {
    let id: UUID
    let hostProfileID: UUID
    let profileSnapshot: HostProfile
    private(set) var title: String
    let createdAt: Date
    let host: SSHTerminalHost
    private(set) var isPinned = false
    private(set) var hasUnseenOutput = false

    init(
        id: UUID = UUID(),
        profileSnapshot: HostProfile,
        title: String,
        createdAt: Date = Date(),
        host: SSHTerminalHost
    ) {
        self.id = id
        self.hostProfileID = profileSnapshot.id
        self.profileSnapshot = profileSnapshot
        self.title = title
        self.createdAt = createdAt
        self.host = host
    }

    func displayName(from profiles: [HostProfile]) -> String {
        profiles.first { $0.id == hostProfileID }?.displayName ?? profileSnapshot.displayName
    }

    func applyTitle(_ title: String) {
        self.title = title
    }

    func applyPinned(_ isPinned: Bool) {
        self.isPinned = isPinned
    }

    func applyHasUnseenOutput(_ hasUnseenOutput: Bool) {
        self.hasUnseenOutput = hasUnseenOutput
    }

    var accessibilityLabel: String {
        var parts = [title, host.state.rowStatusPhrase]
        if isPinned {
            parts.append("pinned")
        }
        if hasUnseenOutput {
            parts.append("new output")
        }
        return parts.joined(separator: ", ")
    }
}

struct TerminalHostGroup: Identifiable {
    var id: UUID { hostProfileID }
    let hostProfileID: UUID
    let displayName: String
    let sessions: [TerminalSession]
    let canOpenNewTerminal: Bool

    @MainActor
    var newOutputCount: Int {
        sessions.filter { $0.hasUnseenOutput }.count
    }

    @MainActor
    func accessibilitySummary(isExpanded: Bool) -> String {
        let count = sessions.count
        let noun = count == 1 ? "terminal" : "terminals"
        var parts = ["\(displayName), \(count) \(noun)"]
        if newOutputCount == 1 {
            parts.append("1 with new output")
        } else if newOutputCount > 1 {
            parts.append("\(newOutputCount) with new output")
        }
        parts.append(isExpanded ? "expanded" : "collapsed")
        return parts.joined(separator: ", ")
    }
}

struct TerminalSessionRoute: Hashable, Identifiable {
    let id: UUID
}

extension SSHTerminalHostState {
    var isRetryable: Bool {
        switch self {
        case .failed, .ended:
            true
        default:
            false
        }
    }

    var rowStatusPhrase: String {
        switch self {
        case .idle: "starting"
        case .connecting: "connecting"
        case .connected: "connected"
        case .ended: "ended"
        case .failed(let message):
            if RemoteLaunchDiagnostics.looksLikeAuthenticationFailure(message) {
                "failed, authentication failed"
            } else {
                "failed, \(RemoteLaunchDiagnostics.sanitizedReason(message))"
            }
        case .closed: "closed"
        }
    }
}
