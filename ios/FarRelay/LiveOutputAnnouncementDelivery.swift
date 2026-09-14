import SwiftUI

/// Serializes announcement delivery for the whole app. Posting multiple
/// UIAccessibility announcements in one run-loop turn is lossy on physical
/// VoiceOver: the last post can replace earlier posts before speech starts.
/// The service therefore batches the current FIFO window into one semantic
/// announcement and keeps later sessions separate and cancellable.
@MainActor
final class DynamicReadingDeliveryService {
    typealias Sink = @MainActor (String) -> Void

    private let sink: Sink
    private let quietInterval: Duration
    private var pending: [DynamicReadingAnnouncement] = []
    private var worker: Task<Void, Never>?

    init(
        quietInterval: Duration = .milliseconds(350),
        sink: @escaping Sink
    ) {
        self.quietInterval = quietInterval
        self.sink = sink
    }

    var pendingCount: Int { pending.count }

    func enqueue(_ announcements: [DynamicReadingAnnouncement]) {
        guard !announcements.isEmpty else { return }
        pending.append(contentsOf: announcements)
        startWorkerIfNeeded()
    }

    func cancel(sessionID: UUID) {
        pending.removeAll { $0.sessionID == sessionID }
        if pending.isEmpty {
            worker?.cancel()
            worker = nil
        }
    }

    func reset() {
        pending.removeAll()
        worker?.cancel()
        worker = nil
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !pending.isEmpty {
                let batch = pending
                pending.removeAll()
                let text = batch.map(\.text).joined(separator: " ")
                if !text.isEmpty { sink(text) }
                if !pending.isEmpty {
                    try? await Task.sleep(for: quietInterval)
                }
            }
            worker = nil
        }
    }
}

/// Thin platform delivery boundary; policy decisions remain framework-neutral.
@MainActor
enum LiveOutputAnnouncementDelivery {
    static let dynamicReading = DynamicReadingDeliveryService { text in
        AccessibilityNotification.Announcement(text).post()
    }

    static func deliver(_ announcement: LiveOutputAnnouncement) {
        AccessibilityNotification.Announcement(announcement.text).post()
    }

    static func deliver(_ announcements: [DynamicReadingAnnouncement]) {
        dynamicReading.enqueue(announcements)
    }

    static func cancelDynamicReading(sessionID: UUID) {
        dynamicReading.cancel(sessionID: sessionID)
    }
}
