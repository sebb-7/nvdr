import Foundation

/// Deterministic thresholds for compact large-output conversation presentation.
///
/// A response block is treated as large when it reaches 50 logical lines or
/// 4,000 characters. The full immutable text is retained for Snapshot and Copy;
/// only the conversation list presentation and live announcement become compact.
public enum TerminalConversationOutputLimits: Sendable {
    public static let largeOutputLineCount = 50
    public static let largeOutputCharacterCount = 4_000

    public static func isLarge(lineCount: Int, characterCount: Int) -> Bool {
        lineCount >= largeOutputLineCount || characterCount >= largeOutputCharacterCount
    }

    public static func isLarge(_ text: String) -> Bool {
        isLarge(
            lineCount: AccessibleConversationEntry.logicalLineCount(in: text),
            characterCount: text.count
        )
    }
}
