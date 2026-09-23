import SwiftUI

struct HostProfileEditorView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TerminalSessionManager.self) private var terminals
    @Environment(BridgeClient.self) private var bridge
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HostProfile
    @State private var credentials = HostProfileCredentials()
    @State private var saveFailed = false
    @State private var openedTerminal: TerminalSessionRoute?
    @State private var confirmingDisconnect = false

    init(profile: HostProfile?) {
        _draft = State(initialValue: profile ?? HostProfile())
    }

    var body: some View {
        Form {
            if isSavedComputer {
                Section("Actions") {
                    Button(isComputerConnected ? "Disconnect" : "Connect", systemImage: "network") {
                        if isComputerConnected {
                            if terminals.activeSessionCount(for: draft.id) > 0 {
                                confirmingDisconnect = true
                            } else {
                                disconnectComputer()
                            }
                        } else {
                            connectComputer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
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
                    if draft.isRemSoundReceiverEnabled {
                        NavigationLink {
                            RemSoundAudioFeatureView(profile: draft)
                        } label: {
                            Label("RemSound Audio", systemImage: "speaker.wave.2")
                        }
                    }
                    if draft.isMacRemoteEnabled {
                        NavigationLink {
                            MacRemoteFeatureView(profile: draft)
                        } label: {
                            Label("Mac Remote", systemImage: "laptopcomputer.and.arrow.down")
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
                    Toggle("Configure RemSound audio receiver", isOn: Binding(
                        get: { draft.remSoundReceiver != nil },
                        set: { configured in
                            draft.remSoundReceiver = configured ? (draft.remSoundReceiver ?? RemSoundReceiverCapability(senderHost: draft.address)) : nil
                        }
                    ))
                    if draft.remSoundReceiver != nil {
                        Toggle("Enable RemSound audio receiver", isOn: Binding(
                            get: { draft.remSoundReceiver?.isEnabled ?? false },
                            set: { draft.remSoundReceiver?.isEnabled = $0 }
                        ))
                        TextField("Windows RemSound address", text: Binding(
                            get: { draft.remSoundReceiver?.senderHost ?? "" },
                            set: { draft.remSoundReceiver?.senderHost = $0 }
                        ))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("RemSound audio UDP port", value: Binding(
                            get: { Int(draft.remSoundReceiver?.senderPort ?? 47_830) },
                            set: { draft.remSoundReceiver?.senderPort = UInt16(clamping: $0) }
                        ), format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        SecureField("RemSound shared password", text: $credentials.remSoundPassword)
                        Text("Enter the Windows PC's LAN or Tailscale address. When audio starts, FarRelay announces this iPhone or iPad directly to the Windows RemSound app, then receives encrypted audio on the configured UDP port. The shared password must match the Windows RemSound profile.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if draft.platform == .macOS {
                Section("Accessibility") {
                    Toggle("Enable Mac Remote", isOn: Binding(
                        get: { draft.macRemote?.isEnabled ?? false },
                        set: { enabled in draft.macRemote = MacRemoteCapability(isEnabled: enabled) }
                    ))
                    Text("The installed FarRelay Mac app supplies its bundled host proxy automatically. The iPhone or iPad connects through SSH; no NVDA Remote channel is used.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                    if !saveFailed {
                        if !isNew {
                            AccessibilityNotification.Announcement("Computer saved").post()
                        }
                        dismiss()
                    }
                }
            }
        }
        .alert(
            "Disconnect \(draft.displayName)?",
            isPresented: $confirmingDisconnect
        ) {
            Button("Disconnect Computer", role: .destructive) {
                disconnectComputer()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(disconnectConfirmationMessage)
        }
        .task { credentials = settings.credentials(for: draft) ?? HostProfileCredentials() }
    }

    private var isSavedComputer: Bool {
        settings.hostProfiles.contains { $0.id == draft.id }
    }

    private var isComputerConnected: Bool {
        bridge.isConnectionActive(for: draft.id) || terminals.hasActiveConnection(for: draft.id)
    }

    private var disconnectConfirmationMessage: String {
        let terminalCount = terminals.activeSessionCount(for: draft.id)
        if terminalCount == 1 {
            return "This closes 1 active terminal and the NVDA Remote bridge for this computer."
        } else {
            return "This closes \(terminalCount) active terminals and the NVDA Remote bridge for this computer."
        }
    }

    private func connectComputer() {
        guard let profile = settings.hostProfiles.first(where: { $0.id == draft.id }) else { return }
        if profile.isNVDARemoteEnabled {
            bridge.start(settings: settings, profile: profile)
        } else {
            Task {
                if let session = await terminals.openTerminal(for: profile, settings: settings) {
                    openedTerminal = TerminalSessionRoute(id: session.id)
                }
            }
        }
    }

    private func disconnectComputer() {
        let profileID = draft.id
        bridge.stop(for: profileID)
        Task {
            await terminals.closeAll(for: profileID)
        }
    }
}
