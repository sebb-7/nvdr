import Foundation
import Observation

/// Semantic interaction categories. Hardware haptics and earcons are mapped
/// from these values at the app boundary, not inside terminal or NVDA models.
public enum InteractionFeedbackKind: Equatable, Hashable, Sendable {
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

    public var category: InteractionFeedbackCategory {
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

public enum InteractionFeedbackCategory: Equatable, Sendable {
    case selection
    case success
    case warning
    case error
}

public struct InteractionFeedbackRequest: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: InteractionFeedbackKind

    public init(id: UUID = UUID(), kind: InteractionFeedbackKind) {
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
public final class InteractionFeedback {
    private let settings: AppSettings
    public private(set) var lastRequest: InteractionFeedbackRequest?

    public init(settings: AppSettings) {
        self.settings = settings
    }

    public func play(_ kind: InteractionFeedbackKind) {
        lastRequest = InteractionFeedbackRequest(kind: kind)
        if settings.soundCuesEnabled {
            InteractionSoundCue.play(kind)
        }
    }
}
