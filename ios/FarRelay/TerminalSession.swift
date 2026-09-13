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
    let title: String
    let createdAt: Date
    let host: SSHTerminalHost

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
}

struct TerminalHostGroup: Identifiable {
    var id: UUID { hostProfileID }
    let hostProfileID: UUID
    let displayName: String
    let sessions: [TerminalSession]
    let canOpenNewTerminal: Bool

    var accessibilityLabel: String {
        let count = sessions.count
        let noun = count == 1 ? "terminal" : "terminals"
        return "\(displayName), \(count) \(noun)"
    }
}

struct TerminalSessionRoute: Hashable, Identifiable {
    let id: UUID
}
