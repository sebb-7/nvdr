import SwiftUI
import UIKit

/// Native editable surface for VoiceOver Braille Screen Input. The local value
/// exists for editing feedback only; edits are mirrored immediately and the
/// full buffer is never sent or logged.
struct TextModeEntryView: View {
    @Bindable var controller: DualSenseControllerAdapter

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    RemoteTextModeEditor(controller: controller)
                        .frame(minHeight: 120)
                } footer: {
                    Text("Text is sent live. Three-finger swipe up in Braille Screen Input sends Enter, closes Text Mode, and returns to Quick Navigation. Swipe left to delete. Once the local session is empty, further deletes remove pre-existing remote text. R3 also sends a remote Backspace.")
                }
            }
            .navigationTitle("Text Mode")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Paste Clipboard", systemImage: "doc.on.clipboard") {
                        _ = controller.pasteClipboardIntoTextMode()
                    }
                    .accessibilityHint("Appends the current iPhone clipboard to Text Mode and sends it to the remote computer.")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { controller.exitTextMode() }
                }
            }
        }
    }
}

enum TextModeInputPolicy {
    static func requestsSubmitAndExit(replacementText: String) -> Bool {
        replacementText.contains("\n") || replacementText.contains("\r")
    }
}

/// UIKit-backed text surface so native VoiceOver/BSI deleteBackward is visible
/// even when the local Text Mode buffer is already empty.
@MainActor
struct RemoteTextModeEditor: UIViewRepresentable {
    let controller: DualSenseControllerAdapter

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> RemoteTextModeTextView {
        let textView = RemoteTextModeTextView()
        textView.delegate = context.coordinator
        textView.onDeleteBackwardWhenEmpty = { [weak controller] in
            controller?.handleTextModeDeleteBackwardWhenLocalBufferEmpty()
        }
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.accessibilityLabel = "Remote text entry"
        textView.accessibilityHint = "Text is sent live. Three-finger swipe up sends Enter and exits Text Mode. Text Mode supports appending, clipboard paste, and deleting from the end."
        textView.text = controller.textModeBuffer
        context.coordinator.moveCaretToEnd(textView)

        DispatchQueue.main.async { [weak textView] in
            textView?.becomeFirstResponder()
        }
        return textView
    }

    func updateUIView(_ textView: RemoteTextModeTextView, context: Context) {
        if textView.text != controller.textModeBuffer {
            textView.text = controller.textModeBuffer
        }
        context.coordinator.moveCaretToEnd(textView)
        if !textView.isFirstResponder {
            DispatchQueue.main.async { [weak textView] in
                textView?.becomeFirstResponder()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        let controller: DualSenseControllerAdapter

        init(controller: DualSenseControllerAdapter) {
            self.controller = controller
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            if TextModeInputPolicy.requestsSubmitAndExit(replacementText: replacement) {
                controller.submitTextModeAndExit()
                return false
            }

            let end = (textView.text as NSString).length

            if replacement.isEmpty {
                // Text Mode v1 supports suffix deletion only.
                return range.length > 0 && NSMaxRange(range) == end
            }

            // Text Mode v1 supports append-at-end only. Reject cursor/selection
            // replacement rather than guessing the corresponding remote edit.
            return range.length == 0 && range.location == end
        }

        func textViewDidChange(_ textView: UITextView) {
            let accepted = controller.applyTextModeEditorValue(textView.text)
            if textView.text != accepted {
                textView.text = accepted
            }
            moveCaretToEnd(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let end = (textView.text as NSString).length
            guard textView.selectedRange.location != end || textView.selectedRange.length != 0 else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.moveCaretToEnd(textView)
            }
        }

        func moveCaretToEnd(_ textView: UITextView) {
            let end = (textView.text as NSString).length
            if textView.selectedRange.location != end || textView.selectedRange.length != 0 {
                textView.selectedRange = NSRange(location: end, length: 0)
            }
        }
    }
}

@MainActor
final class RemoteTextModeTextView: UITextView {
    var onDeleteBackwardWhenEmpty: (() -> Void)?

    override func deleteBackward() {
        if text.isEmpty {
            onDeleteBackwardWhenEmpty?()
            return
        }
        super.deleteBackward()
    }
}
