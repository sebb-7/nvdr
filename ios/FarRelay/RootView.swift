import SwiftUI

struct RootView: View {
    @Environment(BridgeClient.self) private var bridge
    @Environment(SSHTerminalHost.self) private var terminalHost
    @State private var selectedTab: AppShellTab = .home
    @State private var showingSettings = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: .home) {
                NavigationStack { HomeTabView(showingSettings: $showingSettings) }
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
        .onChange(of: selectedTab) { _, newTab in
            if newTab != .home { bridge.suspendInputForInactiveContext() }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }
}

private struct HomeTabView: View {
    @Environment(AppSettings.self) private var settings
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
                                Text("\(profile.platform.label) · \(profile.username)@\(profile.address):\(profile.port)")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
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
            ToolbarItem(placement: .topBarLeading) { Button("Settings", systemImage: "gear") { showingSettings = true } }
            ToolbarItem(placement: .topBarTrailing) { Button("Add Computer", systemImage: "plus") { addingProfile = true } }
        }
        .sheet(isPresented: $addingProfile) {
            NavigationStack { HostProfileEditorView(profile: nil) }
        }
    }
}

private struct TerminalsTabView: View {
    let host: SSHTerminalHost
    @State private var isExpanded = true

    var body: some View {
        List {
            if let profile = host.activeProfile {
                DisclosureGroup(profile.displayName, isExpanded: $isExpanded) {
                    NavigationLink {
                        SSHTerminalFeatureView(host: host, profile: profile, ownsLifecycle: false)
                    } label: {
                        Label("Active Terminal", systemImage: "terminal")
                    }
                }
            } else {
                ContentUnavailableView("No active terminals", systemImage: "terminal", description: Text("Open a terminal from a computer on Home."))
            }
        }
        .navigationTitle("Terminals")
    }
}

private struct EmptyFeatureView: View {
    let title: String
    let message: String
    var body: some View {
        ContentUnavailableView(title, systemImage: "tray", description: Text(message)).navigationTitle(title)
    }
}
