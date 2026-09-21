import SwiftUI
import UIKit

/// Local-only Braille Screen Input surface for one-shot Quick Commands.
/// Unlike Text Mode, editing never mirrors characters remotely. Only the
/// explicit Send Command action can start remote input.
struct QuickCommandEntryView: View {
    @Bindable var controller: DualSenseControllerAdapter

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    QuickCommandTextEditor(controller: controller)
                        .frame(minHeight: 120)
                } footer: {
                    Text("Plus means keys together. Comma means then. Examples: ctrl+v or win+r,powershell,enter. Nothing is sent while you type.")
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
                        _ = controller.sendQuickCommand()
                    }
                    .disabled(controller.quickCommandBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("Parses and sends this one-shot command to the active Windows/NVDA or Mac Remote keyboard target.")
                }
            }
        }
    }
}

@MainActor
private struct QuickCommandTextEditor: UIViewRepresentable {
    let controller: DualSenseControllerAdapter

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
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
        textView.accessibilityHint = "Type a local command. Plus means together and comma means then. Nothing is sent until Send Command."
        textView.text = controller.quickCommandBuffer

        DispatchQueue.main.async { [weak textView] in
            textView?.becomeFirstResponder()
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != controller.quickCommandBuffer {
            textView.text = controller.quickCommandBuffer
        }
        if !textView.isFirstResponder {
            DispatchQueue.main.async { [weak textView] in
                textView?.becomeFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let controller: DualSenseControllerAdapter

        init(controller: DualSenseControllerAdapter) {
            self.controller = controller
        }

        func textViewDidChange(_ textView: UITextView) {
            controller.updateQuickCommandBuffer(textView.text)
        }
    }
}
