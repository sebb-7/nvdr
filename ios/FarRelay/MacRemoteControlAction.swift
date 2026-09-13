import Foundation

/// Stable semantic Remote Control actions for one macOS HostProfile.
///
/// Button titles and VoiceOver host mappings are provisional until physical
/// Mac mini validation. They are not yet wired through RemoteIntent.
enum MacRemoteControlAction: String, CaseIterable, Identifiable, Sendable, Equatable {
    case previousItem
    case nextItem
    case moveUp
    case moveDown
    case interact
    case stopInteracting
    case activate
    case refreshState

    var id: String { rawValue }

    var buttonTitle: String {
        switch self {
        case .previousItem: "Previous"
        case .nextItem: "Next"
        case .moveUp: "Up"
        case .moveDown: "Down"
        case .interact: "Interact"
        case .stopInteracting: "Stop Interacting"
        case .activate: "Activate"
        case .refreshState: "Refresh"
        }
    }

    /// Provisional `voiceover.move` mapping. Activate and Refresh do not move.
    var moveDirection: VoiceOverMoveDirection? {
        switch self {
        case .previousItem: .left
        case .nextItem: .right
        case .moveUp: .up
        case .moveDown: .down
        case .interact: .into
        case .stopInteracting: .out
        case .activate, .refreshState: nil
        }
    }

    var refreshesStateAfterSuccess: Bool {
        self != .refreshState
    }
}
