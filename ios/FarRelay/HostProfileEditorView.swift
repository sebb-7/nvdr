import SwiftUI

struct HostProfileEditorView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HostProfile
    @State private var credentials = HostProfileCredentials()
    @State private var saveFailed = false

    init(profile: HostProfile?) {
        _draft = State(initialValue: profile ?? HostProfile())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Computer") {
                    TextField("Name", text: $draft.displayName)
                    TextField("SSH address", text: $draft.address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", value: $draft.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    TextField("Username", text: $draft.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Authentication", selection: $draft.authenticationMode) {
                        ForEach(SSHAuthMode.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section("Credentials") {
                    if draft.authenticationMode == .password {
                        SecureField("Password", text: $credentials.password)
                    } else {
                        TextEditor(text: $credentials.privateKeyPEM)
                            .font(.caption.monospaced())
                            .frame(minHeight: 120)
                            .accessibilityLabel("Private key")
                        SecureField("Key passphrase (blank if none)", text: $credentials.privateKeyPassphrase)
                    }
                }
                Section("Commands") {
                    TextField("Host protocol command", text: $draft.farRelayHostCommand)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("NVDA bridge command", text: $draft.nvdaBridgeCommand)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("The host protocol uses farrelay-host. NVDA uses the separate farrelay --ipc bridge command.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if saveFailed {
                    Text("Unable to save this computer. Check Keychain access and try again.")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Computer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveFailed = !settings.saveProfile(draft, credentials: credentials)
                        if !saveFailed { dismiss() }
                    }
                }
            }
            .task { credentials = settings.credentials(for: draft) ?? HostProfileCredentials() }
        }
    }
}
