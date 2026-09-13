import SwiftUI

extension InteractionFeedbackKind {
    var sensoryFeedback: SensoryFeedback {
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

extension View {
    /// Delivers haptics for the latest semantic feedback request.
    /// Sound cues are played by `InteractionFeedback` itself so they stay
    /// independent of this modifier.
    func interactionHaptics(
        _ feedback: InteractionFeedback,
        enabled: Bool
    ) -> some View {
        self
            .sensoryFeedback(.selection, trigger: feedback.lastRequest?.id) { _, _ in
                enabled && feedback.lastRequest?.kind == .selectionAccepted
            }
            .sensoryFeedback(.success, trigger: feedback.lastRequest?.id) { _, _ in
                enabled && (feedback.lastRequest?.kind == .success || feedback.lastRequest?.kind == .copied)
            }
            .sensoryFeedback(.warning, trigger: feedback.lastRequest?.id) { _, _ in
                enabled && feedback.lastRequest?.kind == .warning
            }
            .sensoryFeedback(.error, trigger: feedback.lastRequest?.id) { _, _ in
                enabled && feedback.lastRequest?.kind == .error
            }
    }
}
