import Foundation

/// One provider-neutral, informational accessibility announcement.
struct LiveOutputAnnouncement: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// Conditions under which automatic live output may inform without interrupting
/// a person who is reading history, entering input, or inspecting a Snapshot.
struct LiveOutputAnnouncementContext: Equatable, Sendable {
    var isVoiceOverEnabled = false
    var isReadingHistory = false
    var isInputFocused = false
    var isSnapshotInspecting = false

    var permitsAnnouncements: Bool {
        isVoiceOverEnabled && !isReadingHistory && !isInputFocused && !isSnapshotInspecting
    }
}

struct LiveOutputAnnouncementSchedule: Equatable, Sendable {
    let token: UUID
    let delay: Duration
}

enum LiveOutputAnnouncementPolicyEffect: Equatable, Sendable {
    case announce(LiveOutputAnnouncement)
    case schedule(LiveOutputAnnouncementSchedule)
    case cancelScheduled
}

/// Semantic coalescing policy for live conversation output. It deliberately
/// has no terminal-parser, SSH, SwiftUI, or VoiceOver dependency.
@MainActor
final class LiveOutputAnnouncementPolicy {
    /// Long enough to avoid byte-by-byte chatter while remaining responsive
    /// for ordinary interactive terminal output.
    static let defaultQuietInterval: Duration = .milliseconds(450)

    private struct PendingStreaming {
        let token: UUID
        let entryID: UUID
        let text: String
    }

    private let quietInterval: Duration
    private var pendingStreaming: PendingStreaming?
    private var lastHandledTextByEntryID: [UUID: String] = [:]

    init(quietInterval: Duration = LiveOutputAnnouncementPolicy.defaultQuietInterval) {
        self.quietInterval = quietInterval
    }

    func completed(
        _ entries: [AccessibleConversationEntry],
        context: LiveOutputAnnouncementContext
    ) -> [LiveOutputAnnouncementPolicyEffect] {
        var effects: [LiveOutputAnnouncementPolicyEffect] = []
        if let pendingStreaming,
           entries.contains(where: { $0.id == pendingStreaming.entryID }) {
            self.pendingStreaming = nil
            effects.append(.cancelScheduled)
        }
        guard context.permitsAnnouncements else {
            recordSuppressed(entries)
            return effects
        }
        let newEntries = entries.filter { entry in
            !entry.liveAnnouncementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && lastHandledTextByEntryID[entry.id] != entry.liveAnnouncementText
        }
        guard !newEntries.isEmpty else { return effects }
        for entry in newEntries {
            lastHandledTextByEntryID[entry.id] = entry.liveAnnouncementText
        }
        effects.append(.announce(LiveOutputAnnouncement(
            text: newEntries.map(\.liveAnnouncementText).joined(separator: "\n")
        )))
        return effects
    }

    func streaming(
        _ entry: AccessibleConversationEntry,
        context: LiveOutputAnnouncementContext
    ) -> [LiveOutputAnnouncementPolicyEffect] {
        var effects = cancelPendingIfNeeded()
        guard !entry.liveAnnouncementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return effects }
        guard context.permitsAnnouncements else {
            lastHandledTextByEntryID[entry.id] = entry.liveAnnouncementText
            return effects
        }
        guard lastHandledTextByEntryID[entry.id] != entry.liveAnnouncementText else { return effects }
        let pending = PendingStreaming(token: UUID(), entryID: entry.id, text: entry.liveAnnouncementText)
        pendingStreaming = pending
        effects.append(.schedule(LiveOutputAnnouncementSchedule(token: pending.token, delay: quietInterval)))
        return effects
    }

    func settle(
        token: UUID,
        context: LiveOutputAnnouncementContext
    ) -> [LiveOutputAnnouncementPolicyEffect] {
        guard let pendingStreaming, pendingStreaming.token == token else { return [] }
        self.pendingStreaming = nil
        guard context.permitsAnnouncements,
              lastHandledTextByEntryID[pendingStreaming.entryID] != pendingStreaming.text else { return [] }
        lastHandledTextByEntryID[pendingStreaming.entryID] = pendingStreaming.text
        return [.announce(LiveOutputAnnouncement(text: pendingStreaming.text))]
    }

    func updateContext(_ context: LiveOutputAnnouncementContext) -> [LiveOutputAnnouncementPolicyEffect] {
        context.permitsAnnouncements ? [] : cancelPendingIfNeeded()
    }

    func cancelPending() -> [LiveOutputAnnouncementPolicyEffect] {
        cancelPendingIfNeeded()
    }

    func reset() -> [LiveOutputAnnouncementPolicyEffect] {
        lastHandledTextByEntryID = [:]
        return cancelPendingIfNeeded()
    }

    private func cancelPendingIfNeeded() -> [LiveOutputAnnouncementPolicyEffect] {
        guard pendingStreaming != nil else { return [] }
        pendingStreaming = nil
        return [.cancelScheduled]
    }

    private func recordSuppressed(_ entries: [AccessibleConversationEntry]) {
        for entry in entries where !entry.liveAnnouncementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastHandledTextByEntryID[entry.id] = entry.liveAnnouncementText
        }
    }
}
