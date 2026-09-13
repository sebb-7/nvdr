import Foundation
import Observation

/// App-owned collection of live terminal sessions. Each session has its own
/// `SSHTerminalHost` / SSH / PTY / presentation stack. Navigation and tab
/// lifetime do not close sessions; only an explicit close does.
@Observable
@MainActor
final class TerminalSessionManager {
    private(set) var sessions: [TerminalSession] = []
    /// The terminal currently presented for interaction. RemoteIntent uses this
    /// together with `isTerminalInteractionActive` so intents never operate a
    /// hidden or arbitrary session.
    private(set) var presentedSessionID: UUID?
    private(set) var isTerminalInteractionActive = false

    private let connectionFactory: any SSHTerminalHostConnectionFactory
    private var titleSequence: [UUID: Int] = [:]
    private var hostAppearanceOrder: [UUID] = []

    init(
        connectionFactory: any SSHTerminalHostConnectionFactory = ProductionSSHTerminalHostConnectionFactory()
    ) {
        self.connectionFactory = connectionFactory
    }

    func session(id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    func sessions(for hostProfileID: UUID) -> [TerminalSession] {
        sessions.filter { $0.hostProfileID == hostProfileID }
    }

    func hostGroups(using profiles: [HostProfile]) -> [TerminalHostGroup] {
        hostAppearanceOrder.compactMap { hostID in
            let hostSessions = sessions.filter { $0.hostProfileID == hostID }
            guard !hostSessions.isEmpty else { return nil }
            let displayName = profiles.first { $0.id == hostID }?.displayName
                ?? hostSessions[0].profileSnapshot.displayName
            return TerminalHostGroup(
                hostProfileID: hostID,
                displayName: displayName,
                sessions: hostSessions,
                canOpenNewTerminal: profiles.contains { $0.id == hostID }
            )
        }
    }

    /// Creates a new independent terminal for a saved computer. Returns nil when
    /// that HostProfile is no longer saved, so a stale group cannot mint sessions.
    @discardableResult
    func openTerminal(for profile: HostProfile, settings: AppSettings) async -> TerminalSession? {
        guard settings.hostProfiles.contains(where: { $0.id == profile.id }) else { return nil }
        let nextIndex = (titleSequence[profile.id] ?? 0) + 1
        titleSequence[profile.id] = nextIndex
        if !hostAppearanceOrder.contains(profile.id) {
            hostAppearanceOrder.append(profile.id)
        }
        let session = TerminalSession(
            profileSnapshot: profile,
            title: "Terminal \(nextIndex)",
            host: SSHTerminalHost(connectionFactory: connectionFactory)
        )
        sessions.append(session)
        await session.host.start(settings: settings, profile: profile)
        return session
    }

    func close(_ id: UUID) async {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        await session.host.close()
        sessions.removeAll { $0.id == id }
        if presentedSessionID == id {
            presentedSessionID = nil
        }
        if sessions(for: session.hostProfileID).isEmpty {
            titleSequence[session.hostProfileID] = 0
            hostAppearanceOrder.removeAll { $0 == session.hostProfileID }
        }
    }

    func closeAll() async {
        let ids = sessions.map(\.id)
        for id in ids {
            await close(id)
        }
    }

    func present(_ id: UUID?) {
        if let id {
            guard sessions.contains(where: { $0.id == id }) else { return }
            presentedSessionID = id
        } else {
            presentedSessionID = nil
        }
    }

    func clearPresentedSession(if id: UUID) {
        if presentedSessionID == id {
            presentedSessionID = nil
        }
    }

    func setTerminalInteractionActive(_ active: Bool) {
        isTerminalInteractionActive = active
    }

    var currentTerminalPresentation: TerminalPresentationModel? {
        guard isTerminalInteractionActive, let presentedSessionID else { return nil }
        return session(id: presentedSessionID)?.host.presentation
    }
}
