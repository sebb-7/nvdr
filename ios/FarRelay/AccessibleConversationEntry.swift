import Foundation

/// The semantic role of one entry in an accessible conversation transcript.
///
/// This intentionally stays small: the SSH terminal is the first provider to
/// use it, without coupling the representation to agents, SSH, or a view.
public enum AccessibleConversationEntryRole: Equatable, Sendable {
    case outboundCommand
    case incomingContent
    case system
}

/// Immutable-identity transcript content presented through native SwiftUI
/// accessibility semantics.
public struct AccessibleConversationEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public let role: AccessibleConversationEntryRole

    public init(
        id: UUID = UUID(),
        text: String,
        role: AccessibleConversationEntryRole
    ) {
        self.id = id
        self.text = text
        self.role = role
    }

    public var isCommand: Bool {
        role == .outboundCommand
    }
}
