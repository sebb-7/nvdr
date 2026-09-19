import SwiftUI

/// Native editable surface for VoiceOver Braille Screen Input. The local value
/// exists for editing feedback only; edits are mirrored immediately and the
/// full buffer is never sent or logged.
struct TextModeEntryView: View {
    @Bindable var controller: DualSenseControllerAdapter
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Remote text entry", text: Binding(
                        get: { controller.textModeBuffer },
                        set: { _ = controller.applyTextModeEditorValue($0) }
                    ), axis: .vertical)
                        .focused($focused)
                        .accessibilityHint("Text is sent live. Text Mode supports appending and deleting from the end.")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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

}
