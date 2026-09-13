import Foundation

/// Named VoiceOver rotor actions for terminal conversation and input.
enum ConversationAccessibilityAction: String, Equatable, Hashable, CaseIterable, Sendable {
    case copy = "Copy"
    case runAgain = "Run Again"
    case openSnapshot = "Open Snapshot"
    case sendCommand = "Send Command"
    case clearInput = "Clear Input"
    case copyAll = "Copy All"

    var name: String { rawValue }
}

/// Testable policy for which Actions-rotor items a conversation surface exposes.
enum ConversationAccessibilityActionPolicy {
    static func actions(for entry: AccessibleConversationEntry) -> [ConversationAccessibilityAction] {
        switch entry.role {
        case .outboundCommand:
            [.copy, .runAgain]
        case .incomingContent:
            [.copy, .openSnapshot]
        case .system:
            [.copy]
        }
    }

    static func inputActions(inputText: String) -> [ConversationAccessibilityAction] {
        if inputText.isEmpty {
            [.sendCommand]
        } else {
            [.sendCommand, .clearInput]
        }
    }

    static func copyText(for entry: AccessibleConversationEntry) -> String {
        entry.text
    }

    static func copyAllText(for snapshot: AccessibleConversationSnapshot) -> String {
        snapshot.text
    }
}
