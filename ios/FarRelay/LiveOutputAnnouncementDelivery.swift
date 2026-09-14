import SwiftUI
import UIKit

/// Serializes announcement delivery for the whole app. UIKit exposes
/// `announcementDidFinishNotification`, so the next item is not posted until
/// VoiceOver reports that the current item finished. A timer cannot establish
/// this boundary: speech duration varies with verbosity, language, and user
/// speech rate.
@MainActor
final class DynamicReadingDeliveryService {
    typealias Sink = @MainActor (NSAttributedString) -> Void

    private let sink: Sink
    private var pending: [DynamicReadingAnnouncement] = []
    private var active: DynamicReadingAnnouncement?
    private var finishObserver: NSObjectProtocol?

    init(
        sink: @escaping Sink
    ) {
        self.sink = sink
        finishObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.announcementDidFinishNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleFinish(notification)
            }
        }
    }

    deinit {
        if let finishObserver {
            NotificationCenter.default.removeObserver(finishObserver)
        }
    }

    var pendingCount: Int { pending.count }
    var activeText: String? { active?.text }

    func enqueue(_ announcements: [DynamicReadingAnnouncement]) {
        guard !announcements.isEmpty else { return }
        pending.append(contentsOf: announcements)
        deliverNextIfIdle()
    }

    func cancel(sessionID: UUID) {
        pending.removeAll { $0.sessionID == sessionID }
        if active?.sessionID == sessionID {
            // We cannot cancel speech already owned by VoiceOver through a
            // public API. Drop it from FarRelay's logical queue so a later
            // session cannot be blocked behind stale state; the speech
            // attribute keeps any newly posted item behind system speech.
            active = nil
            deliverNextIfIdle()
        }
    }

    func reset() {
        pending.removeAll()
        active = nil
    }

    /// Testable seam for the UIKit finish notification and useful when a
    /// host-specific accessibility adapter forwards the same event.
    func announcementDidFinish(text: String? = nil) {
        guard let active else { return }
        guard text == nil || text == active.text else { return }
        self.active = nil
        deliverNextIfIdle()
    }

    private func handleFinish(_ notification: Notification) {
        let text = notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey]
            as? String
        announcementDidFinish(text: text)
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
