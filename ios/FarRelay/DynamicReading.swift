import Foundation

/// Shared, provider-neutral state for streaming accessibility announcements.
/// It is deliberately UIKit-free so ordering, coalescing, and cancellation can
/// be tested without VoiceOver or a terminal session.
struct DynamicReadingContext: Equatable, Sendable {
    var enabled = true
    var isVoiceOverEnabled = false
    var isReadingHistory = false
    var isSnapshotInspecting = false

    var permitsAnnouncements: Bool {
        enabled && isVoiceOverEnabled && !isReadingHistory && !isSnapshotInspecting
    }
}

struct DynamicReadingAnnouncement: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let text: String

    init(id: UUID = UUID(), sessionID: UUID, text: String) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
    }
}

/// A small FIFO with per-entry coalescing. Updating a streaming entry replaces
/// only its queued value; unrelated entries retain their original order.
@MainActor
final class DynamicReadingQueue {
    private struct Pending: Equatable {
        let entryID: UUID
        let sessionID: UUID
        var text: String
    }

    private var order: [UUID] = []
    private var pending: [UUID: Pending] = [:]
    private var deliveredTextByEntry: [UUID: String] = [:]

    func enqueue(
        entryID: UUID,
        sessionID: UUID,
        text: String,
        context: DynamicReadingContext
    ) {
        guard context.permitsAnnouncements else {
            deliveredTextByEntry[entryID] = text
            return
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, deliveredTextByEntry[entryID] != normalized else { return }
        if pending[entryID] != nil {
            pending[entryID]?.text = normalized
        } else {
            order.append(entryID)
            pending[entryID] = Pending(entryID: entryID, sessionID: sessionID, text: normalized)
        }
    }

    func cancel(sessionID: UUID) {
        let ids = pending.values.filter { $0.sessionID == sessionID }.map(\.entryID)
        ids.forEach { pending.removeValue(forKey: $0) }
        order.removeAll { ids.contains($0) }
        deliveredTextByEntry = deliveredTextByEntry.filter { id, _ in !ids.contains(id) }
    }

    func reset() {
        order.removeAll()
        pending.removeAll()
        deliveredTextByEntry.removeAll()
    }

    func drain() -> [DynamicReadingAnnouncement] {
        let announcements = order.compactMap { entryID -> DynamicReadingAnnouncement? in
            guard let item = pending.removeValue(forKey: entryID) else { return nil }
            deliveredTextByEntry[entryID] = item.text
            return DynamicReadingAnnouncement(sessionID: item.sessionID, text: item.text)
        }
        order.removeAll()
        return announcements
    }
}
