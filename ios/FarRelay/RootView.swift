import SwiftUI

struct RootView: View {
    @Environment(BridgeClient.self) private var bridge
    @Environment(SSHTerminalHost.self) private var terminalHost
    @State private var selectedTab: AppShellTab = .home
    @State private var showingSettings = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: .home) {
                NavigationStack { HomeTabView(host: terminalHost, showingSettings: $showingSettings) }
            }
            Tab("NVDA", systemImage: "accessibility", value: .nvda) {
                NavigationStack { NVDATabView() }
            }
            Tab("Terminals", systemImage: "terminal", value: .terminals) {
                NavigationStack { TerminalsTabView(host: terminalHost) }
            }
            Tab("Agents", systemImage: "person.2", value: .agents) {
                NavigationStack { EmptyFeatureView(title: "Agents", message: "No agents configured yet.") }
            }
            Tab("Assistant", systemImage: "sparkles", value: .assistant) {
                NavigationStack { EmptyFeatureView(title: "Assistant", message: "Assistant is not configured yet.") }
            }
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            if oldTab == .nvda, newTab != .nvda { bridge.suspendInputForInactiveContext() }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }
}

private struct HomeTabView: View {
    @Environment(AppSettings.self) private var settings
    let host: SSHTerminalHost
    @Binding var showingSettings: Bool
    @State private var addingProfile = false

    var body: some View {
        List {
            if settings.hostProfiles.isEmpty {
                ContentUnavailableView("No computers", systemImage: "desktopcomputer", description: Text("Add a computer to connect over SSH."))
            } else {
                Section("Computers") {
                    ForEach(settings.hostProfiles) { profile in
                        NavigationLink {
                            HostProfileEditorView(profile: profile)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(profile.displayName)
                                Text("\(profile.username)@\(profile.address):\(profile.port)")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        NavigationLink("Open Terminal", systemImage: "terminal") {
                            SSHTerminalFeatureView(host: host, profile: profile)
                        }
                    }
                    .onDelete { indexes in
                        for index in indexes { _ = settings.deleteProfile(settings.hostProfiles[index]) }
                    }
                }
            }
            if let error = settings.credentialStorageError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .navigationTitle("FarRelay")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gear") { showingSettings = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Computer", systemImage: "plus") { addingProfile = true }
            }
        }
        .sheet(isPresented: $addingProfile) { HostProfileEditorView(profile: nil) }
    }
}

private struct TerminalsTabView: View {
    @Environment(AppSettings.self) private var settings
    let host: SSHTerminalHost

    var body: some View {
        List {
            if settings.hostProfiles.isEmpty {
                ContentUnavailableView("No computers", systemImage: "terminal", description: Text("Add a computer on the Home tab before opening a terminal."))
            } else {
                Section("Choose a computer") {
                    ForEach(settings.hostProfiles) { profile in
                        NavigationLink {
                            SSHTerminalFeatureView(host: host, profile: profile)
                        } label: {
                            Label(profile.displayName, systemImage: "terminal")
                        }
                    }
                }
                Section {
                    Text("FarRelay currently keeps one active terminal session. Opening another computer replaces that active session.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Terminals")
    }
}

private struct NVDATabView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Computer") {
                if settings.hostProfiles.isEmpty {
                    Text("Add a computer on the Home tab before connecting NVDA.")
                } else {
                    Picker("Computer", selection: $settings.selectedNVDAProfileID) {
                        ForEach(settings.hostProfiles) { profile in
                            Text(profile.displayName).tag(Optional(profile.id))
                        }
                    }
                    Button(isConnected ? "Disconnect" : "Connect", systemImage: "network") {
                        if isConnected { bridge.stop() }
                        else if let profile = settings.selectedNVDAProfile { bridge.start(settings: settings, profile: profile) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Section("Status") { Text(statusLabel) }
            Section("Keyboard forwarding") {
                Toggle("Forward keystrokes to slave", isOn: $bridge.forwardingEnabled)
                    .disabled(!isForwardingAvailable)
                Text(isForwardingAvailable ? "Turn this off to use the keyboard locally." : "Connect first.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Last spoken") { Text(bridge.lastSpeech.isEmpty ? "—" : bridge.lastSpeech) }
            Section("Log") {
                ForEach(bridge.log.indices, id: \.self) { Text(bridge.log[$0]).font(.caption.monospaced()) }
            }
        }
        .navigationTitle("NVDA")
        .overlay { KeyboardCapture(bridge: bridge, settings: settings).frame(height: 0) }
        .onDisappear { bridge.suspendInputForInactiveContext() }
    }

    private var isConnected: Bool {
        switch bridge.status {
        case .ready, .connecting, .authenticating, .reconnecting, .nvdaNotConnected: true
        default: false
        }
    }

    private var isForwardingAvailable: Bool {
        switch bridge.status { case .ready, .nvdaNotConnected: true; default: false }
    }

    private var statusLabel: String {
        switch bridge.status {
        case .idle: "Idle"
        case .connecting: "Connecting"
        case .authenticating: "Authenticating"
        case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))"
        case .ready: "Ready"
        case .nvdaNotConnected: "Connected, no NVDA on channel"
        case .disconnected(let reason): "Disconnected (\(reason))"
        case .failed(let message): "Failed: \(message)"
        }
    }
}

private struct EmptyFeatureView: View {
    let title: String
    let message: String
    var body: some View {
        ContentUnavailableView(title, systemImage: "tray", description: Text(message))
            .navigationTitle(title)
    }
}
