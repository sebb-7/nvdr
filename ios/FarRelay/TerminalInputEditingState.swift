import Foundation

/// The terminal's one local input owner. VoiceOver focus can request editing,
/// but UIKit first-responder callbacks confirm it; transcript browsing never
/// becomes remote-key forwarding.
enum TerminalInputEditingState: Equatable, Sendable {
    case browsing
    case editing

    mutating func activateInput() {
        self = .editing
    }

    mutating func didBeginEditing() {
        self = .editing
    }

    mutating func didEndEditing() {
        self = .browsing
    }

    mutating func submissionCompleted() {
        // A terminal submission does not transfer ownership to transcript
        // output. The persistent UIKit editor remains ready for BSI.
        self = .editing
    }

    mutating func leaveTerminal() {
        self = .browsing
    }

    var isEditing: Bool {
        self == .editing
    }
}
