import Foundation
import Observation

/// Semantic interaction categories. Hardware haptics and earcons are mapped
/// from these values at the app boundary, not inside terminal or NVDA models.
enum InteractionFeedbackKind: Equatable, Hashable, Sendable {
    /// An ordinary accepted action such as Send, a Control Key, or Open Snapshot.
    case selectionAccepted
    /// A successful connection or similarly conclusive success.
    case success
    /// Disconnect or a now-unavailable action.
    case warning
    /// A failed action or failed connection.
    case error
    /// Clipboard copy succeeded.
    case copied

    var category: InteractionFeedbackCategory {
        switch self {
        case .selectionAccepted:
            .selection
        case .success, .copied:
            .success
        case .warning:
            .warning
        case .error:
            .error
        }
    }
}

enum InteractionFeedbackCategory: Equatable, Sendable {
    case selection
    case success
    case warning
    case error
}

struct InteractionFeedbackRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: InteractionFeedbackKind

    init(id: UUID = UUID(), kind: InteractionFeedbackKind) {
        self.id = id
        self.kind = kind
    }
}

/// App-level player for sparse, meaningful interaction feedback.
///
/// Terminal and NVDA models emit `InteractionFeedbackKind` values. This type
/// owns preference checks, earcon playback, and the trigger used by SwiftUI
/// sensory feedback. It does not own terminal parsing or NVDA transport.
@Observable
@MainActor
final class InteractionFeedback {
    private let settings: AppSettings
    private let soundSettings: InteractionSoundSettings
    private(set) var lastRequest: InteractionFeedbackRequest?

    init(settings: AppSettings, soundSettings: InteractionSoundSettings) {
        self.settings = settings
        self.soundSettings = soundSettings
    }

    func play(_ kind: InteractionFeedbackKind) {
        lastRequest = InteractionFeedbackRequest(kind: kind)
        playConfiguredSound(soundIntent(for: kind))
    }

    func play(_ intent: InteractionSoundIntent, haptic: InteractionFeedbackKind? = nil) {
        if let haptic { lastRequest = InteractionFeedbackRequest(kind: haptic) }
        playConfiguredSound(intent)
    }

    private func playConfiguredSound(_ intent: InteractionSoundIntent) {
        guard settings.soundCuesEnabled else { return }
        let preference = soundSettings.preference(for: intent)
        guard preference.isEnabled else { return }
        InteractionSoundCue.playBundled(filename: preference.filename)
    }

    private func soundIntent(for kind: InteractionFeedbackKind) -> InteractionSoundIntent {
        switch kind {
        case .selectionAccepted: .action
        case .success: .success
        case .warning: .warning
        case .error: .error
        case .copied: .copied
        }
    }
}
