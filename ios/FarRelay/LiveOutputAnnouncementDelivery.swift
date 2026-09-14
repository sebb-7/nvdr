import SwiftUI
import UIKit

/// Serializes announcement delivery for the whole app. UIKit exposes
/// `announcementDidFinishNotification`, so the next item is not posted until
/// VoiceOver reports that the current item finished. A timer cannot establish
/// this boundary: speech duration varies with verbosity, language, and user
/// speech rate. UIKit's global completion notification has no app-issued
/// announcement ID, so correlation is by the active announcement's exact
/// string; an unrelated announcement with identical text is an explicit
/// platform limitation and is ignored unless it matches that text.
@MainActor
final class DynamicReadingDeliveryService {
    typealias Sink = @MainActor (NSAttributedString) -> Void

    private let sink: Sink
    private var pending: [DynamicReadingAnnouncement] = []
    private var active: DynamicReadingAnnouncement?
    private var finishObserver: NSObjectProtocol?
    private var startTask: Task<Void, Never>?

    init(
        sink: @escaping Sink
    ) {
        self.sink = sink
        finishObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.announcementDidFinishNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let text = notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey]
                as? String
            let successful = (notification.userInfo?[UIAccessibility.announcementWasSuccessfulUserInfoKey]
                as? NSNumber)?.boolValue ?? false
            Task { @MainActor [weak self] in
                self?.announcementDidFinish(text: text, successful: successful)
            }
        }
    }

    var pendingCount: Int { pending.count }
    var activeText: String? { active?.text }

    func enqueue(_ announcements: [DynamicReadingAnnouncement]) {
        guard !announcements.isEmpty else { return }
        pending.append(contentsOf: announcements)
        scheduleStartIfNeeded()
    }

    func cancel(sessionID: UUID) {
        pending.removeAll { $0.sessionID == sessionID }
        if active?.sessionID == sessionID {
            // We cannot cancel speech already owned by VoiceOver through a
            // public API. Drop it from FarRelay's logical queue so a later
            // session cannot be blocked behind stale state; the speech
            // attribute keeps any newly posted item behind system speech.
            active = nil
            scheduleStartIfNeeded()
        } else if pending.isEmpty {
            startTask?.cancel()
            startTask = nil
        }
    }

    func reset() {
        pending.removeAll()
        active = nil
        startTask?.cancel()
        startTask = nil
    }

    /// Testable seam for the UIKit finish notification and useful when a
    /// host-specific accessibility adapter forwards the same event.
    func announcementDidFinish(text: String? = nil, successful: Bool = true) {
        guard let active else { return }
        guard text == nil || text == active.text else { return }
        guard successful else {
            // An interruption is the user's decision to stop automatic
            // reading. Do not immediately speak the rest of the queue.
            pending.removeAll()
            startTask?.cancel()
            startTask = nil
            self.active = nil
            return
        }
        self.active = nil
        scheduleStartIfNeeded()
    }

    private func scheduleStartIfNeeded() {
        guard active == nil, startTask == nil, !pending.isEmpty else { return }
        // Give same-turn session/context cancellation a chance before the
        // first UIKit post. This is also the boundary that prevents a stale
        // terminal update from escaping during a SwiftUI reconstruction.
        startTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.startTask = nil
            self?.deliverNextIfIdle()
        }
    }

    private func deliverNextIfIdle() {
        guard active == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        active = next
        // Queue behind speech already owned by VoiceOver. The coordinator
        // still guarantees that FarRelay never submits two of its own items.
        let value = NSMutableAttributedString(string: next.text)
        value.addAttribute(
            .accessibilitySpeechQueueAnnouncement,
            value: true,
            range: NSRange(location: 0, length: value.length)
        )
        sink(value)
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
