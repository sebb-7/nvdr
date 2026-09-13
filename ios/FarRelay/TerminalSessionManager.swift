import Foundation
import Observation

/// App-owned collection of live terminal sessions. Each session has its own
/// `SSHTerminalHost` / SSH / PTY / presentation stack. Navigation and tab
/// lifetime do not close sessions; only an explicit close does.
///
/// Display order is independent of the identity array. Within one computer
/// group, pinned sessions sort above unpinned sessions, and each category is
/// newest-first unless the user explicitly moves a session. Passive output and
/// connection status never reorder sessions or host groups.
///
/// Retry creates a replacement `TerminalSession` with a new `SSHTerminalHost`
/// because one host object is one terminal lifetime. The failed session stays
/// inspectable; its transcript is not erased.
@Observable
@MainActor
final class TerminalSessionManager {
    private(set) var sessions: [TerminalSession] = []
    /// The terminal currently presented for interaction. RemoteIntent uses this
    /// together with `isTerminalInteractionActive` so intents never operate a
    /// hidden or arbitrary session.
    private(set) var presentedSessionID: UUID?
    private(set) var isTerminalInteractionActive = false
    private(set) var lastConnectionAnnouncement: ConnectionAnnouncement?
    private(set) var lastInteractionFeedback: InteractionFeedbackRequest?
    private(set) var presentedIssue: UserFacingIssue?

    private let connectionFactory: any SSHTerminalHostConnectionFactory
    private var titleSequence: [UUID: Int] = [:]
    private var hostAppearanceOrder: [UUID] = []
    private var pinnedIDsByHost: [UUID: [UUID]] = [:]
    private var unpinnedIDsByHost: [UUID: [UUID]] = [:]

    init(
        connectionFactory: any SSHTerminalHostConnectionFactory = ProductionSSHTerminalHostConnectionFactory()
    ) {
        self.connectionFactory = connectionFactory
    }

    func session(id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    func sessions(for hostProfileID: UUID) -> [TerminalSession] {
        orderedSessions(for: hostProfileID)
    }

    func activeSessionCount(for hostProfileID: UUID) -> Int {
        sessions.filter { $0.hostProfileID == hostProfileID }.count
    }

    func hostGroups(using profiles: [HostProfile]) -> [TerminalHostGroup] {
        hostAppearanceOrder.compactMap { hostID in
            let hostSessions = orderedSessions(for: hostID)
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

    func capabilities(for id: UUID) -> TerminalSessionCapabilities {
        guard let session = session(id: id),
              let index = indexInCategory(id) else {
            return TerminalSessionCapabilities(
                canPin: false,
                canUnpin: false,
                canRename: false,
                canRetry: false,
                canMoveUp: false,
                canMoveDown: false,
                canClose: false
            )
        }
        let categoryCount = categoryIDs(for: session).count
        return TerminalSessionCapabilities(
            canPin: !session.isPinned,
            canUnpin: session.isPinned,
            canRename: true,
            canRetry: session.host.state.isRetryable,
            canMoveUp: index > 0,
            canMoveDown: index + 1 < categoryCount,
            canClose: true
        )
    }

    func accessibilityActions(for id: UUID) -> [TerminalSessionAccessibilityAction] {
        TerminalSessionActionPolicy.actions(for: capabilities(for: id))
    }

    /// Creates a new independent terminal for a saved computer. Returns nil when
    /// that HostProfile is no longer saved, so a stale group cannot mint sessions.
    @discardableResult
    func openTerminal(for profile: HostProfile, settings: AppSettings) async -> TerminalSession? {
        guard settings.hostProfiles.contains(where: { $0.id == profile.id }) else { return nil }
        let nextIndex = (titleSequence[profile.id] ?? 0) + 1
        titleSequence[profile.id] = nextIndex
        let session = TerminalSession(
            profileSnapshot: profile,
            title: "Terminal \(nextIndex)",
            host: SSHTerminalHost(connectionFactory: connectionFactory)
        )
        insertNewUnpinned(session)
        promoteHost(profile.id)
        attach(session)
        await session.host.start(settings: settings, profile: profile)
        return session
    }

    func pin(_ id: UUID) {
        guard let session = session(id: id), !session.isPinned else { return }
        removeFromCategoryLists(id)
        session.applyPinned(true)
        prepend(id, hostID: session.hostProfileID, pinned: true)
        requestFeedback(.selectionAccepted)
    }

    func unpin(_ id: UUID) {
        guard let session = session(id: id), session.isPinned else { return }
        removeFromCategoryLists(id)
        session.applyPinned(false)
        prepend(id, hostID: session.hostProfileID, pinned: false)
        requestFeedback(.selectionAccepted)
    }

    @discardableResult
    func rename(_ id: UUID, to rawTitle: String) -> Bool {
        guard let session = session(id: id) else { return false }
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        session.applyTitle(trimmed)
        requestFeedback(.success)
        return true
    }

    func moveUp(_ id: UUID) {
        move(id, offset: -1)
    }

    func moveDown(_ id: UUID) {
        move(id, offset: 1)
    }

    /// Keeps the failed or ended session inspectable and starts a replacement
    /// with a new `SSHTerminalHost`. The replacement uses the same title.
    @discardableResult
    func retry(_ id: UUID, settings: AppSettings) async -> TerminalSession? {
        guard let original = session(id: id), original.host.state.isRetryable else { return nil }
        let replacement = TerminalSession(
            profileSnapshot: original.profileSnapshot,
            title: original.title,
            host: SSHTerminalHost(connectionFactory: connectionFactory)
        )
        insertNewUnpinned(replacement)
        promoteHost(original.hostProfileID)
        attach(replacement)
        requestFeedback(.selectionAccepted)
        presentedIssue = nil
        let profile = settings.hostProfiles.first { $0.id == original.hostProfileID } ?? original.profileSnapshot
        await replacement.host.start(settings: settings, profile: profile)
        return replacement
    }

    func close(_ id: UUID) async {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        await session.host.close()
        removeFromCategoryLists(id)
        sessions.removeAll { $0.id == id }
        if presentedSessionID == id {
            presentedSessionID = nil
        }
        if presentedIssue?.retry == .terminal(id) {
            presentedIssue = nil
        }
        if sessions.filter({ $0.hostProfileID == session.hostProfileID }).isEmpty {
            titleSequence[session.hostProfileID] = 0
            hostAppearanceOrder.removeAll { $0 == session.hostProfileID }
            pinnedIDsByHost[session.hostProfileID] = nil
            unpinnedIDsByHost[session.hostProfileID] = nil
        }
        requestFeedback(.warning)
    }

    func closeAll() async {
        let ids = sessions.map(\.id)
        for id in ids {
            await close(id)
        }
    }

    func present(_ id: UUID?) {
        if let id {
            guard let session = session(id: id) else { return }
            presentedSessionID = id
            session.applyHasUnseenOutput(false)
            promoteHost(session.hostProfileID)
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

    func noteIncomingOutput(from sessionID: UUID) {
        guard let session = session(id: sessionID) else { return }
        let isViewingThisTerminal = isTerminalInteractionActive && presentedSessionID == sessionID
        if !isViewingThisTerminal {
            session.applyHasUnseenOutput(true)
        }
    }

    func dismissPresentedIssue() {
        presentedIssue = nil
    }

    func retryPresentedIssue(_ issue: UserFacingIssue, settings: AppSettings) async {
        presentedIssue = nil
        switch issue.retry {
        case .terminal(let id):
            _ = await retry(id, settings: settings)
        case .nvda:
            break
        case nil:
            break
        }
    }

    var currentTerminalPresentation: TerminalPresentationModel? {
        guard isTerminalInteractionActive, let presentedSessionID else { return nil }
        return session(id: presentedSessionID)?.host.presentation
    }

    private func orderedSessions(for hostID: UUID) -> [TerminalSession] {
        let pinned = (pinnedIDsByHost[hostID] ?? []).compactMap { session(id: $0) }
        let unpinned = (unpinnedIDsByHost[hostID] ?? []).compactMap { session(id: $0) }
        return pinned + unpinned
    }

    private func insertNewUnpinned(_ session: TerminalSession) {
        sessions.append(session)
        prepend(session.id, hostID: session.hostProfileID, pinned: false)
    }

    private func prepend(_ id: UUID, hostID: UUID, pinned: Bool) {
        if pinned {
            var ids = pinnedIDsByHost[hostID] ?? []
            ids.removeAll { $0 == id }
            ids.insert(id, at: 0)
            pinnedIDsByHost[hostID] = ids
        } else {
            var ids = unpinnedIDsByHost[hostID] ?? []
            ids.removeAll { $0 == id }
            ids.insert(id, at: 0)
            unpinnedIDsByHost[hostID] = ids
        }
    }

    private func promoteHost(_ hostID: UUID) {
        hostAppearanceOrder.removeAll { $0 == hostID }
        hostAppearanceOrder.insert(hostID, at: 0)
    }

    private func attach(_ session: TerminalSession) {
        let sessionID = session.id
        session.host.onStateChange = { [weak self] old, new in
            self?.handleHostStateChange(sessionID: sessionID, from: old, to: new)
        }
        session.host.presentation.onIncomingConversationContent = { [weak self] in
            self?.noteIncomingOutput(from: sessionID)
        }
    }

    private func handleHostStateChange(
        sessionID: UUID,
        from old: SSHTerminalHostState,
        to new: SSHTerminalHostState
    ) {
        guard let session = session(id: sessionID) else { return }
        let computerName = session.profileSnapshot.displayName
        if let text = ConnectionAnnouncementPolicy.terminalAnnouncement(
            from: old,
            to: new,
            computerName: computerName
        ) {
            lastConnectionAnnouncement = ConnectionAnnouncement(text: text)
        }
        switch new {
        case .connected:
            requestFeedback(.success)
        case .failed(let message):
            requestFeedback(.error)
            presentedIssue = RemoteLaunchDiagnostics.terminalFailureIssue(
                computerName: computerName,
                reason: message,
                diagnosticText: RemoteLaunchDiagnostics.diagnosticText(
                    computerName: computerName,
                    address: session.profileSnapshot.address,
                    port: session.profileSnapshot.port,
                    username: session.profileSnapshot.username,
                    reason: message
                ),
                sessionID: sessionID
            )
        default:
            break
        }
    }

    private func move(_ id: UUID, offset: Int) {
        guard let session = session(id: id) else { return }
        var ids = categoryIDs(for: session)
        guard let index = ids.firstIndex(of: id) else { return }
        let newIndex = index + offset
        guard ids.indices.contains(newIndex) else { return }
        ids.swapAt(index, newIndex)
        storeCategoryIDs(ids, for: session)
        requestFeedback(.selectionAccepted)
    }

    private func categoryIDs(for session: TerminalSession) -> [UUID] {
        if session.isPinned {
            pinnedIDsByHost[session.hostProfileID] ?? []
        } else {
            unpinnedIDsByHost[session.hostProfileID] ?? []
        }
    }

    private func storeCategoryIDs(_ ids: [UUID], for session: TerminalSession) {
        if session.isPinned {
            pinnedIDsByHost[session.hostProfileID] = ids
        } else {
            unpinnedIDsByHost[session.hostProfileID] = ids
        }
    }

    private func indexInCategory(_ id: UUID) -> Int? {
        guard let session = session(id: id) else { return nil }
        return categoryIDs(for: session).firstIndex(of: id)
    }

    private func removeFromCategoryLists(_ id: UUID) {
        for hostID in pinnedIDsByHost.keys {
            pinnedIDsByHost[hostID]?.removeAll { $0 == id }
        }
        for hostID in unpinnedIDsByHost.keys {
            unpinnedIDsByHost[hostID]?.removeAll { $0 == id }
        }
    }

    private func requestFeedback(_ kind: InteractionFeedbackKind) {
        lastInteractionFeedback = InteractionFeedbackRequest(kind: kind)
    }
}
