import SwiftUI

/// Thin platform delivery boundary; policy decisions remain framework-neutral.
@MainActor
enum LiveOutputAnnouncementDelivery {
    static func deliver(_ announcement: LiveOutputAnnouncement) {
        AccessibilityNotification.Announcement(announcement.text).post()
    }

    static func deliver(_ announcements: [DynamicReadingAnnouncement]) {
        for announcement in announcements {
            // UIAccessibility announcement notifications are the public
            // VoiceOver queue boundary. Do not add sleeps or speech APIs.
            AccessibilityNotification.Announcement(announcement.text).post()
        }
    }
}
