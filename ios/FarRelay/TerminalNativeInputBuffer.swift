import Foundation

/// Owns the terminal editor's local buffer without publishing every native
/// keystroke into SwiftUI. This keeps Braille Screen Input attached to one
/// stable UIKit text control while command text is being entered.
@MainActor
final class TerminalNativeInputBuffer {
    private(set) var editorID: UUID?
    private(set) var currentText = ""
    private(set) var isEditing = false
    private(set) var isAccessibilityFocused = false
    private(set) var editorReplacementCount = 0

    private var writeNativeText: ((String) -> Void)?

    func attach(editorID: UUID, initialText: String, writeNativeText: @escaping (String) -> Void) {
        if let existingID = self.editorID, existingID != editorID {
            editorReplacementCount += 1
        }
        if self.editorID == nil {
            currentText = initialText
        }
        self.editorID = editorID
        self.writeNativeText = writeNativeText
    }

    func nativeTextDidChange(_ text: String) {
        currentText = text
    }

    func nativeEditingDidBegin() {
        isEditing = true
    }

    func nativeEditingDidEnd() {
        isEditing = false
    }

    func nativeAccessibilityFocusDidChange(_ isFocused: Bool) {
        isAccessibilityFocused = isFocused
    }

    func clear() {
        currentText = ""
        writeNativeText?("")
    }
}
