import SwiftUI
import UIKit

/// Local-only Braille Screen Input surface for one-shot Quick Commands.
/// Unlike Text Mode, editing never mirrors characters remotely. Every send
/// first presents FarRelay's interpretation for explicit confirmation.
struct QuickCommandEntryView: View {
    @Bindable var controller: DualSenseControllerAdapter
    @State private var confirmationMessage = ""
    @State private var isShowingConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    QuickCommandTextEditor(
                        controller: controller,
                        allowsFirstResponder: QuickCommandEditorFocusPolicy.shouldOwnFocus(
                            isShowingConfirmation: isShowingConfirmation
                        ),
                        onSubmit: requestConfirmation
                    )
                    .frame(minHeight: 120)
                } footer: {
                    Text("Plus means keys together. Comma means then. With English UEB Braille Screen Input, type plus as dot 5, then dots 2-3-5. In BSI, three-finger swipe up acts as Return and opens confirmation. Examples: ctrl+v or win+r,powershell,enter. Nothing is sent until you choose Send in the alert.")
                }

                if let status = controller.quickCommandStatus {
                    Section("Status") {
                        Text(status)
                    }
                }
            }
            .navigationTitle("Quick Command")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        controller.exitQuickCommandMode()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send Command") {
                        requestConfirmation()
                    }
                    .disabled(controller.quickCommandBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("Shows FarRelay's interpretation before anything is sent.")
                }
            }
            .alert("Send Quick Command?", isPresented: $isShowingConfirmation) {
                Button("Cancel", role: .cancel) {
                    controller.cancelQuickCommandConfirmation()
                }
                Button("Send") {
                    _ = controller.confirmQuickCommand()
                }
            } message: {
                Text(confirmationMessage)
            }
            .onChange(of: isShowingConfirmation) { _, shown in
                if !shown {
                    controller.cancelQuickCommandConfirmation()
                }
            }
        }
    }

    private func requestConfirmation() {
        guard let preview = controller.prepareQuickCommandForConfirmation() else { return }
        confirmationMessage = preview
        isShowingConfirmation = true
    }
}

enum QuickCommandTextInputPolicy {
    static func requestsConfirmation(replacementText: String) -> Bool {
        replacementText.contains("\n") || replacementText.contains("\r")
    }
}

enum QuickCommandEditorFocusPolicy {
    static func shouldOwnFocus(isShowingConfirmation: Bool) -> Bool {
        !isShowingConfirmation
    }
}

@MainActor
private struct QuickCommandTextEditor: UIViewRepresentable {
    let controller: DualSenseControllerAdapter
    let allowsFirstResponder: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            controller: controller,
            allowsFirstResponder: allowsFirstResponder,
            onSubmit: onSubmit
        )
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.accessibilityLabel = "Quick Command entry"
        textView.accessibilityHint = "Type a local command. Plus means together and comma means then. With English UEB Braille Screen Input, plus is dot 5, then dots 2-3-5. Three-finger swipe up opens confirmation. Nothing is sent until you choose Send in the alert."
        textView.text = controller.quickCommandBuffer

        if allowsFirstResponder {
            DispatchQueue.main.async { [weak textView, weak coordinator = context.coordinator] in
                guard coordinator?.allowsFirstResponder == true else { return }
                textView?.becomeFirstResponder()
            }
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.allowsFirstResponder = allowsFirstResponder
        if textView.text != controller.quickCommandBuffer {
            textView.text = controller.quickCommandBuffer
        }
        if !allowsFirstResponder {
            if textView.isFirstResponder {
                textView.resignFirstResponder()
            }
            return
        }
        if !textView.isFirstResponder {
            DispatchQueue.main.async { [weak textView, weak coordinator = context.coordinator] in
                guard coordinator?.allowsFirstResponder == true else { return }
                textView?.becomeFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let controller: DualSenseControllerAdapter
        var allowsFirstResponder: Bool
        let onSubmit: () -> Void

        init(
            controller: DualSenseControllerAdapter,
            allowsFirstResponder: Bool,
            onSubmit: @escaping () -> Void
        ) {
            self.controller = controller
            self.allowsFirstResponder = allowsFirstResponder
            self.onSubmit = onSubmit
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            if QuickCommandTextInputPolicy.requestsConfirmation(replacementText: replacement) {
                onSubmit()
                return false
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            controller.updateQuickCommandBuffer(textView.text)
        }
    }
}
