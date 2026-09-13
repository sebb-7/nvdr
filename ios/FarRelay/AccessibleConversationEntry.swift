import Foundation

/// The semantic role of one entry in an accessible conversation transcript.
///
/// This intentionally stays small: the SSH terminal is the first provider to
/// use it, without coupling the representation to agents, SSH, or a view.
enum AccessibleConversationEntryRole: Equatable, Sendable {
    case outboundCommand
    case incomingContent
    case system
}

/// Immutable-identity transcript content presented through native SwiftUI
/// accessibility semantics.
struct AccessibleConversationEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    let role: AccessibleConversationEntryRole

    init(
        id: UUID = UUID(),
        text: String,
        role: AccessibleConversationEntryRole
    ) {
        self.id = id
        self.text = text
        self.role = role
    }

    var isCommand: Bool {
        role == .outboundCommand
    }

    var logicalLineCount: Int {
        Self.logicalLineCount(in: text)
    }

    var isCompactLargeOutput: Bool {
        role == .incomingContent && TerminalConversationOutputLimits.isLarge(text)
    }

    /// Conversation-list text. Large incoming blocks stay compact here while
    /// `text` remains the complete logical content for Copy and Snapshot.
    var presentationText: String {
        guard isCompactLargeOutput else { return text }
        return "Large output, \(logicalLineCount) lines. Open Snapshot."
    }

    /// Live VoiceOver announcement text. Large incoming blocks never speak
    /// the full payload automatically.
    var liveAnnouncementText: String {
        guard isCompactLargeOutput else { return text }
        return "Large output received, \(logicalLineCount) lines."
    }

    static func logicalLineCount(in text: String) -> Int {
        if text.isEmpty { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}
