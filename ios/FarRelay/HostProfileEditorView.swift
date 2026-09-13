import SwiftUI

struct HostProfileEditorView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TerminalSessionManager.self) private var terminals
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HostProfile
    @State private var credentials = HostProfileCredentials()
    @State private var saveFailed = false
    @State private var openedTerminal: TerminalSessionRoute?

    init(profile: HostProfile?) {
        _draft = State(initialValue: profile ?? HostProfile())
    }

    var body: some View {
        Form {
            if isSavedComputer {
                Section("Actions") {
                    Button("New Terminal", systemImage: "terminal") {
                        guard let profile = settings.hostProfiles.first(where: { $0.id == draft.id }) else { return }
                        Task {
                            if let session = await terminals.openTerminal(for: profile, settings: settings) {
                                openedTerminal = TerminalSessionRoute(id: session.id)
                            }
                        }
                    }
                    if draft.isNVDARemoteEnabled {
                        NavigationLink {
                            NVDARemoteFeatureView(profile: draft)
                        } label: {
                            Label("NVDA Remote", systemImage: "accessibility")
                        }
                    }
                }
            }
            Section("Computer") {
                TextField("Name", text: $draft.displayName)
                TextField("SSH address", text: $draft.address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", value: $draft.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                TextField("Username", text: $draft.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Platform", selection: $draft.platform) {
                    ForEach(HostPlatform.allCases) { Text($0.label).tag($0) }
                }
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
                Text("The host protocol uses farrelay-host. NVDA uses the separate farrelay --ipc bridge command.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if draft.platform == .windows {
                Section("Accessibility") {
                    Toggle("Configure NVDA Remote", isOn: Binding(
                        get: { draft.nvdaRemote != nil },
                        set: { configured in
                            draft.nvdaRemote = configured ? (draft.nvdaRemote ?? NVDARemoteCapability()) : nil
                        }
                    ))
                    if draft.nvdaRemote != nil {
                        Toggle("Enable NVDA Remote", isOn: Binding(
                            get: { draft.nvdaRemote?.isEnabled ?? false },
                            set: { draft.nvdaRemote?.isEnabled = $0 }
                        ))
                        TextField("Relay host", text: Binding(get: { draft.nvdaRemote?.relayHost ?? "" }, set: { draft.nvdaRemote?.relayHost = $0 }))
                        TextField("Relay port", value: Binding(get: { draft.nvdaRemote?.relayPort ?? 6837 }, set: { draft.nvdaRemote?.relayPort = $0 }), format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                        TextField("Channel key", text: Binding(get: { draft.nvdaRemote?.channel ?? "" }, set: { draft.nvdaRemote?.channel = $0 }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Pinned fingerprint", text: Binding(get: { draft.nvdaRemote?.fingerprint ?? "" }, set: { draft.nvdaRemote?.fingerprint = $0 }))
                        Toggle("Insecure (skip TLS verify)", isOn: Binding(get: { draft.nvdaRemote?.insecure ?? false }, set: { draft.nvdaRemote?.insecure = $0 }))
                        TextField("NVDA bridge command", text: $draft.nvdaBridgeCommand)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
            }
            if saveFailed {
                Text("Unable to save this computer. Check Keychain access and try again.")
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Computer")
        .navigationDestination(item: $openedTerminal) { route in
            if let session = terminals.session(id: route.id) {
                SSHTerminalFeatureView(session: session)
            } else {
                ContentUnavailableView("Terminal closed", systemImage: "terminal", description: Text("This terminal is no longer open."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let isNew = !isSavedComputer
                    saveFailed = !settings.saveProfile(draft, credentials: credentials)
                    if !saveFailed, isNew { dismiss() }
                }
            }
        }
        .task { credentials = settings.credentials(for: draft) ?? HostProfileCredentials() }
    }

    private var isSavedComputer: Bool {
        settings.hostProfiles.contains { $0.id == draft.id }
    }
}
