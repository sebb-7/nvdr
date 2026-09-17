import Foundation

/// Optional rotor actions. Primary activation and essential controls are not
/// represented here and therefore cannot be disabled by the user.
struct VoiceOverActionPreferences: Codable, Equatable, Sendable {
    enum ComputerAction: String, Codable, CaseIterable, Hashable, Sendable {
        case editComputer
        case deleteComputer
    }

    enum TerminalAction: String, Codable, CaseIterable, Hashable, Sendable {
        case pinUnpin, rename, retry, moveUp, moveDown, close
    }

    enum ConversationCommandAction: String, Codable, CaseIterable, Hashable, Sendable {
        case copy, runAgain
    }

    enum ConversationOutputAction: String, Codable, CaseIterable, Hashable, Sendable {
        case copy, openSnapshot
    }

    var computerActions: Set<ComputerAction>
    var terminalActions: Set<TerminalAction>
    var conversationCommandActions: Set<ConversationCommandAction>
    var conversationOutputActions: Set<ConversationOutputAction>

    static let defaults = VoiceOverActionPreferences(
        computerActions: Set(ComputerAction.allCases),
        terminalActions: Set(TerminalAction.allCases),
        conversationCommandActions: Set(ConversationCommandAction.allCases),
        conversationOutputActions: Set(ConversationOutputAction.allCases)
    )
}
