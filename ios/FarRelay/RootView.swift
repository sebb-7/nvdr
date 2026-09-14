import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge
    @Environment(TerminalSessionManager.self) private var terminals
    @Environment(InteractionFeedback.self) private var interactionFeedback
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @SceneStorage("farrelay.selectedTab") private var selectedTabRaw = AppShellTab.home.rawValue
    @State private var selectedTab: AppShellTab = .home
    @State private var showingSettings = false
    @State private var terminalIssue: UserFacingIssue?

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: .home) {
                HomeTabView(showingSettings: $showingSettings)
            }
            Tab("Remote Control", systemImage: "accessibility", value: .remoteControl) {
                RemoteControlTabView()
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
            selectedTabRaw = newTab.rawValue
            if newTab != .remoteControl { bridge.suspendInputForInactiveContext() }
            terminals.setTerminalInteractionActive(false)
        }
        .onAppear { selectedTab = AppShellTab(rawValue: selectedTabRaw) ?? .home }
        .onChange(of: terminals.lastLifecycleEvent?.id) { _, _ in
            handleTerminalLifecycleEvent()
        }
        .onChange(of: terminals.lastSessionActionFeedback?.id) { _, _ in
            if let request = terminals.lastSessionActionFeedback {
                interactionFeedback.play(request.kind)
            }
        }
        .userFacingIssueAlert($terminalIssue, onRetry: retryTerminalIssue)
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .interactionHaptics(interactionFeedback, enabled: settings.hapticFeedbackEnabled)
    }

    private func handleTerminalLifecycleEvent() {
        guard let event = terminals.lastLifecycleEvent,
              let session = terminals.session(id: event.sessionID) else {
            return
        }
        let profile = session.profileSnapshot
        if isVoiceOverEnabled,
           let text = ConnectionAnnouncementPolicy.terminalAnnouncement(
            from: event.previousState,
            to: event.currentState,
            computerName: profile.displayName
           ) {
            AccessibilityNotification.Announcement(text).post()
        }
        switch event.currentState {
        case .connected:
            interactionFeedback.play(.success)
        case .failed(let reason):
            interactionFeedback.play(.error)
            terminalIssue = RemoteLaunchDiagnostics.terminalFailureIssue(
                computerName: profile.displayName,
                reason: reason,
                diagnosticText: RemoteLaunchDiagnostics.diagnosticText(
                    computerName: profile.displayName,
                    address: profile.address,
                    port: profile.port,
                    username: profile.username,
                    reason: reason
                ),
                sessionID: session.id
            )
        default:
            break
        }
    }

    private func retryTerminalIssue(_ issue: UserFacingIssue) {
        terminalIssue = nil
        guard case let .some(.terminal(sessionID)) = issue.retry else { return }
        Task { _ = await terminals.retry(sessionID, settings: settings) }
    }
}

private enum RemoteControlDestination: Hashable {
    case nvda(UUID)
}

private struct RemoteControlTabView: View {
    @Environment(AppSettings.self) private var settings
    @SceneStorage("farrelay.activeRemoteProfileID") private var activeProfileRaw = ""
    @State private var path: [RemoteControlDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Available computers") {
                    let supported = settings.hostProfiles.filter { $0.isNVDARemoteEnabled }
                    if supported.isEmpty {
                        ContentUnavailableView("No remote-control computers", systemImage: "accessibility", description: Text("Enable NVDA Remote on a Windows computer in Home."))
                    } else {
                        ForEach(supported) { profile in
                            NavigationLink(value: RemoteControlDestination.nvda(profile.id)) {
                                Label(profile.displayName, systemImage: "accessibility")
                            }
                        }
                    }
                }
                Section("Coming later") {
                    Label("macOS VoiceOver Remote — not available yet", systemImage: "desktopcomputer").foregroundStyle(.secondary)
                    Label("Linux remote control — not available yet", systemImage: "desktopcomputer").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Remote Control")
            .navigationDestination(for: RemoteControlDestination.self) { destination in
                switch destination {
                case .nvda(let id):
                    if let profile = settings.hostProfiles.first(where: { $0.id == id }) {
                        NVDARemoteFeatureView(profile: profile)
                    } else {
                        ContentUnavailableView("Computer removed", systemImage: "accessibility", description: Text("This computer is no longer saved on Home."))
                    }
                }
            }
        }
        .onAppear {
            guard path.isEmpty, let id = UUID(uuidString: activeProfileRaw), settings.hostProfiles.contains(where: { $0.id == id && $0.isNVDARemoteEnabled }) else { return }
            path = [.nvda(id)]
        }
        .onChange(of: path) { _, newPath in
            if case .nvda(let id) = newPath.last { activeProfileRaw = id.uuidString }
            else if newPath.isEmpty { activeProfileRaw = "" }
        }
    }
}

private enum HomeDestination: Hashable {
    case computer(UUID)
    case nvda(UUID)
    case terminal(UUID)
}

private struct HomeTabView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TerminalSessionManager.self) private var terminals
    @Binding var showingSettings: Bool
    @State private var addingProfile = false
    @State private var path = NavigationPath()
    @State private var pendingDeletion: HostProfile?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if settings.hostProfiles.isEmpty {
                    ContentUnavailableView("No computers", systemImage: "desktopcomputer", description: Text("Add a computer to connect over SSH."))
                } else {
                    Section("Computers") {
                        ForEach(settings.hostProfiles) { profile in
                            NavigationLink(value: HomeDestination.computer(profile.id)) {
                                VStack(alignment: .leading) {
                                    Text(profile.displayName)
                                    Text("\(profile.platform.label) · \(profile.username)@\(profile.address):\(profile.port)")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .namedAccessibilityActions(
                                HostProfileActionPolicy.actions(for: profile),
                                name: \.name
                            ) { action in
                                perform(action, for: profile)
                            }
                        }
                        .onDelete { indexes in
                            if let index = indexes.first {
                                pendingDeletion = settings.hostProfiles[index]
                            }
                        }
                    }
                }
                if let error = settings.credentialStorageError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("FarRelay")
            .navigationDestination(for: HomeDestination.self) { destination in
                HomeDestinationView(destination: destination)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Settings", systemImage: "gear") { showingSettings = true } }
                ToolbarItem(placement: .topBarTrailing) { Button("Add Computer", systemImage: "plus") { addingProfile = true } }
            }
            .sheet(isPresented: $addingProfile) {
                NavigationStack { HostProfileEditorView(profile: nil) }
            }
            .alert(
                "Delete \(pendingDeletion?.displayName ?? "Computer")?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { profile in
                Button("Delete Computer", role: .destructive) {
                    _ = settings.deleteProfile(profile)
                    pendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: { profile in
                Text(
                    HostProfileDeletionPolicy.confirmationMessage(
                        computerName: profile.displayName,
                        activeTerminalCount: terminals.activeSessionCount(for: profile.id)
                    )
                )
            }
        }
    }

    private func perform(_ action: HostProfileAccessibilityAction, for profile: HostProfile) {
        switch action {
        case .newTerminal:
            Task {
                if let session = await terminals.openTerminal(for: profile, settings: settings) {
                    path.append(HomeDestination.terminal(session.id))
                }
            }
        case .nvdaRemote:
            path.append(HomeDestination.nvda(profile.id))
        case .edit:
            path.append(HomeDestination.computer(profile.id))
        case .delete:
            pendingDeletion = profile
        }
    }
}

private struct HomeDestinationView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TerminalSessionManager.self) private var terminals
    let destination: HomeDestination

    var body: some View {
        switch destination {
        case .computer(let id):
            if let profile = settings.hostProfiles.first(where: { $0.id == id }) {
                HostProfileEditorView(profile: profile)
            } else {
                ContentUnavailableView(
                    "Computer removed",
                    systemImage: "desktopcomputer",
                    description: Text("This computer is no longer saved on Home.")
                )
            }
        case .nvda(let id):
            if let profile = settings.hostProfiles.first(where: { $0.id == id }) {
                NVDARemoteFeatureView(profile: profile)
            } else {
                ContentUnavailableView(
                    "Computer removed",
                    systemImage: "accessibility",
                    description: Text("This computer is no longer saved on Home.")
                )
            }
        case .terminal(let id):
            if let session = terminals.session(id: id) {
                SSHTerminalFeatureView(session: session)
            } else {
                ContentUnavailableView("Terminal closed", systemImage: "terminal", description: Text("This terminal is no longer open."))
            }
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
                TerminalSessionRow(
                    session: session,
                    openedTerminal: $openedTerminal
                )
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
            Text(group.accessibilitySummary(isExpanded: isExpanded))
        }
    }
}

private struct TerminalSessionRow: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TerminalSessionManager.self) private var manager
    let session: TerminalSession
    @Binding var openedTerminal: TerminalSessionRoute?
    @State private var showingRename = false
    @State private var renameDraft = ""

    var body: some View {
        Button {
            openedTerminal = TerminalSessionRoute(id: session.id)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(session.title)
                    Text(session.host.state.statusLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .namedAccessibilityActions(
            manager.accessibilityActions(for: session.id),
            name: \.name
        ) { action in
            perform(action)
        }
        .alert("Rename Terminal", isPresented: $showingRename) {
            TextField("Title", text: $renameDraft)
            Button("Save") {
                _ = manager.rename(session.id, to: renameDraft)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for this terminal.")
        }
    }

    private func perform(_ action: TerminalSessionAccessibilityAction) {
        switch action {
        case .open:
            openedTerminal = TerminalSessionRoute(id: session.id)
        case .pin:
            manager.pin(session.id)
        case .unpin:
            manager.unpin(session.id)
        case .rename:
            renameDraft = session.title
            showingRename = true
        case .retry:
            Task { _ = await manager.retry(session.id, settings: settings) }
        case .moveUp:
            manager.moveUp(session.id)
        case .moveDown:
            manager.moveDown(session.id)
        case .close:
            Task { await manager.close(session.id) }
        }
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
