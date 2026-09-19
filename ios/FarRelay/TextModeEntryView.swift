import SwiftUI

/// Native editable surface for VoiceOver Braille Screen Input. The local value
/// exists for editing feedback only; edits are mirrored immediately and the
/// full buffer is never sent or logged.
struct TextModeEntryView: View {
    @Bindable var controller: DualSenseControllerAdapter
    @State private var text = ""
    @State private var previousText = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Remote text entry", text: $text, axis: .vertical)
                        .focused($focused)
                        .accessibilityHint("Text is sent to the focused field on the remote computer as you type.")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: text) { _, newValue in mirrorChange(to: newValue) }
                } footer: {
                    Text("Text is sent live. R3 sends a remote Backspace even when this field is empty.")
                }
            }
            .navigationTitle("Text Mode")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { controller.exitTextMode() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func mirrorChange(to newValue: String) {
        let old = Array(previousText)
        let new = Array(newValue)
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        if new.count > old.count {
            controller.mirrorTextInsertion(Array(new.dropFirst(prefix)))
        } else if new.count < old.count {
            controller.mirrorTextBackspace(count: old.count - new.count)
        }
        previousText = newValue
    }
}
