import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge
    @Environment(TerminalSessionManager.self) private var terminals
    @Environment(InteractionFeedback.self) private var interactionFeedback
    @State private var selectedTab: AppShellTab = .home
    @State private var showingSettings = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: .home) {
                NavigationStack { HomeTabView(showingSettings: $showingSettings) }
            }
            Tab("Terminals", systemImage: "terminal", value: .terminals) {
                NavigationStack { TerminalsTabView() }
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
            terminals.setTerminalInteractionActive(false)
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .interactionHaptics(interactionFeedback, enabled: settings.hapticFeedbackEnabled)
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
    @Environment(AppSettings.self) private var settings
    @Environment(TerminalSessionManager.self) private var manager
    @State private var expandedHostIDs: Set<UUID> = []
    @State private var openedTerminal: TerminalSessionRoute?
    @State private var showingNewTerminalPicker = false

    var body: some View {
        let groups = manager.hostGroups(using: settings.hostProfiles)
        List {
            if groups.isEmpty {
                ContentUnavailableView(
                    "No active terminals",
                    systemImage: "terminal",
                    description: Text("Open New Terminal from Home or this tab.")
                )
            } else {
                ForEach(groups) { group in
                    HostTerminalGroupView(
                        group: group,
                        isExpanded: expansionBinding(for: group.id),
                        openedTerminal: $openedTerminal
                    )
                }
            }
        }
        .navigationTitle("Terminals")
        .navigationDestination(item: $openedTerminal) { route in
            TerminalSessionDestination(route: route)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Terminal", systemImage: "plus") {
                    showingNewTerminalPicker = true
                }
            }
        }
        .sheet(isPresented: $showingNewTerminalPicker) {
            NewTerminalComputerPicker { sessionID in
                openedTerminal = TerminalSessionRoute(id: sessionID)
            }
        }
        .onChange(of: groups.map(\.id)) { _, newIDs in
            for id in newIDs where !expandedHostIDs.contains(id) {
                expandedHostIDs.insert(id)
            }
            expandedHostIDs.formIntersection(Set(newIDs))
        }
        .onAppear {
            for group in groups {
                expandedHostIDs.insert(group.id)
            }
        }
    }

    private func expansionBinding(for hostID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedHostIDs.contains(hostID) },
            set: { isExpanded in
                if isExpanded { expandedHostIDs.insert(hostID) }
                else { expandedHostIDs.remove(hostID) }
            }
        )
    }
}

private struct HostTerminalGroupView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TerminalSessionManager.self) private var manager
    let group: TerminalHostGroup
    @Binding var isExpanded: Bool
    @Binding var openedTerminal: TerminalSessionRoute?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(group.sessions) { session in
                NavigationLink {
                    SSHTerminalFeatureView(session: session)
                } label: {
                    TerminalSessionRow(session: session)
                }
            }
            if group.canOpenNewTerminal {
                Button("New Terminal", systemImage: "plus") {
                    guard let profile = settings.hostProfiles.first(where: { $0.id == group.hostProfileID }) else { return }
                    Task {
                        if let session = await manager.openTerminal(for: profile, settings: settings) {
                            openedTerminal = TerminalSessionRoute(id: session.id)
                        }
                    }
                }
            }
        } label: {
            Text(group.accessibilityLabel)
        }
    }
}

private struct TerminalSessionRow: View {
    let session: TerminalSession

    var body: some View {
        VStack(alignment: .leading) {
            Text(session.title)
            Text(session.host.state.statusLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TerminalSessionDestination: View {
    @Environment(TerminalSessionManager.self) private var manager
    let route: TerminalSessionRoute

    var body: some View {
        if let session = manager.session(id: route.id) {
            SSHTerminalFeatureView(session: session)
        } else {
            ContentUnavailableView("Terminal closed", systemImage: "terminal", description: Text("This terminal is no longer open."))
        }
    }
}

private struct NewTerminalComputerPicker: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TerminalSessionManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    let onOpened: (UUID) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if settings.hostProfiles.isEmpty {
                    ContentUnavailableView(
                        "No computers",
                        systemImage: "desktopcomputer",
                        description: Text("Add a computer on Home before opening a terminal.")
                    )
                } else {
                    List(settings.hostProfiles) { profile in
                        Button(profile.displayName) {
                            Task {
                                if let session = await manager.openTerminal(for: profile, settings: settings) {
                                    onOpened(session.id)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Terminal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct EmptyFeatureView: View {
    let title: String
    let message: String
    var body: some View {
        ContentUnavailableView(title, systemImage: "tray", description: Text(message)).navigationTitle(title)
    }
}
