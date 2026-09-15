import AppKit
import ServiceManagement
import SwiftUI

private enum MacNavigationSection: String, CaseIterable, Identifiable {
    case computers = "Computers"
    case remoteControl = "Remote Control"
    case terminals = "Terminals"
    case thisMac = "This Mac"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .computers: "desktopcomputer"
        case .remoteControl: "accessibility"
        case .terminals: "terminal"
        case .thisMac: "laptopcomputer"
        case .settings: "gear"
        }
    }
}

struct RootView: View {
    @State private var selection: MacNavigationSection? = .thisMac
    @AppStorage("farrelay.completedMacSetup") private var completedSetup = false

    var body: some View {
        NavigationSplitView {
            List(MacNavigationSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
            }
            .navigationTitle("FarRelay")
        } detail: {
            switch selection ?? .thisMac {
            case .computers: LegacyBridgeView()
            case .remoteControl: RemoteControlOverview()
            case .terminals: TerminalOverview()
            case .thisMac: ThisMacView()
            case .settings: SettingsView()
            }
        }
        .sheet(isPresented: Binding(get: { !completedSetup }, set: { if !$0 { completedSetup = true } })) {
            MacFirstRunSetup(completedSetup: $completedSetup)
        }
        .frame(minWidth: 760, idealWidth: 920, minHeight: 580, idealHeight: 700)
    }
}

private struct RemoteControlOverview: View {
    @Environment(MacHostReadinessModel.self) private var readiness
    @Environment(MacHostService.self) private var host

    var body: some View {
        ContentUnavailableView {
            Label("Mac Remote", systemImage: "accessibility")
        } description: {
            Text("Host status: \(host.diagnostics().readiness.label). Connect a FarRelay controller using this Mac’s SSH account after enabling remote control in This Mac.")
        } actions: {
            Button("Emergency Stop", role: .destructive) { host.emergencyStop() }
            Button("Refresh Status") { readiness.refresh(socketReady: host.socketStatus == "Ready") }
        }
        .navigationTitle("Remote Control")
    }
}

private struct TerminalOverview: View {
    var body: some View {
        ContentUnavailableView("Terminals", systemImage: "terminal", description: Text("SSH terminal sessions are available from the iPhone and iPad client. Mac terminal session composition remains the next native-client step."))
            .navigationTitle("Terminals")
    }
}

private struct ThisMacView: View {
    @Environment(MacHostReadinessModel.self) private var readiness
    @Environment(MacHostService.self) private var host
    @Environment(RemoteSpeechInbox.self) private var inbox
    @Environment(MacRemoteInputEngine.self) private var input
    @State private var startAtLoginError: String?

    var body: some View {
        Form {
            Section("Remote control") {
                @Bindable var readiness = readiness
                Toggle("Allow remote control of this Mac", isOn: $readiness.isEnabled)
                    .onChange(of: readiness.isEnabled) { _, enabled in
                        if enabled { host.startIfEnabled() } else { host.stop() }
                    }
                LabeledContent("Host status", value: host.diagnostics().readiness.label)
                LabeledContent("Local host proxy", value: host.socketStatus)
                LabeledContent("Active controller", value: host.activeControllerID == nil ? "None" : "Connected")
                Button("Stop Remote Control", role: .destructive) { host.stop() }
                Button("Emergency Stop", role: .destructive) { host.emergencyStop() }
            }

            Section("Permissions") {
                LabeledContent("Accessibility permission", value: Permissions.hasAccessibility ? "Granted" : "Required")
                if !Permissions.hasAccessibility {
                    Button("Request Accessibility Permission") { Permissions.requestAccessibility() }
                    Button("Open Accessibility Settings") { Permissions.openAccessibilitySettings() }
                }
                LabeledContent("Input Monitoring permission", value: Permissions.hasInputMonitoring ? "Granted" : "Required")
                if !Permissions.hasInputMonitoring {
                    Button("Request Input Monitoring Permission") { _ = Permissions.requestInputMonitoring() }
                    Button("Open Input Monitoring Settings") { Permissions.openInputMonitoringSettings() }
                }
                Button("Recheck") {
                    input.recheckPermission()
                    readiness.refresh(socketReady: host.socketStatus == "Ready")
                }
            }

            Section("FarRelay Remote Voice") {
                LabeledContent("Provider", value: readiness.providerEmbedded ? "Embedded" : "Missing")
                LabeledContent("VoiceOver status", value: readiness.voiceOverRunning ? "Running" : "Not detected")
                LabeledContent("Semantic events", value: "\(inbox.receivedEventCount)")
                LabeledContent("SSML", value: inbox.ssmlReceived ? "Available" : "Not yet received")
                Button("Test VoiceOver Feedback") { host.refreshSpeech() }
                Text("Select FarRelay Remote Voice in VoiceOver settings, then use VoiceOver to navigate. This test reports event metadata only; it never displays your spoken content.")
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Button("Enable Start at Login") { setStartAtLogin(enabled: true) }
                Button("Disable Start at Login") { setStartAtLogin(enabled: false) }
                if let startAtLoginError { Text(startAtLoginError).foregroundStyle(.red) }
            }

            Section("Feedback capabilities") {
                Text("Semantic VoiceOver is the intended mode. System Audio is an explicit future ScreenCaptureKit fallback and is not enabled or described as VoiceOver-only. Minimal Feedback remains diagnostics-only.")
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Button("Copy Diagnostic Report") { copyReport() }
                Text("The report omits SSH credentials, channels, typed input, and VoiceOver utterance contents.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("This Mac")
    }

    private func setStartAtLogin(enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            startAtLoginError = nil
        } catch {
            startAtLoginError = "Start at Login could not be changed. Check Login Items in System Settings."
        }
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(host.diagnostics().sanitizedReport(), forType: .string)
    }
}

private struct MacFirstRunSetup: View {
    @Binding var completedSetup: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("Welcome to FarRelay Mac Beta") {
                    Text("Complete these checks in This Mac. FarRelay reports live status; it does not use static checkmarks.")
                }
                Section("Before remote control") {
                    Text("1. Enable Accessibility and Input Monitoring permissions.")
                    Text("2. Turn on Allow remote control of this Mac.")
                    Text("3. In VoiceOver settings, select FarRelay Remote Voice and run Test VoiceOver Feedback.")
                    Text("4. Use Copy Diagnostic Report after testing.")
                }
            }
            .navigationTitle("First-run setup")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Continue") { completedSetup = true } } }
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct LegacyBridgeView: View {
    @Environment(KeyCapture.self) private var capture
    @Environment(RemoteSpeechInbox.self) private var remoteSpeechInbox

    var body: some View {
        VStack(spacing: 0) {
            if capture.state != .running {
                PermissionsBanner()
                Divider()
            }
            StatusHeader()
            Divider()
            ConnectionControls()
            Divider()
            ForwardingPanel()
            Divider()
            RemoteSpeechProviderPanel()
            Divider()
            LastSpeechPanel()
            Divider()
            LogPanel()
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 560, idealHeight: 640)
        .toolbar {
            ToolbarItem {
                SettingsLink {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
    }
}

private struct RemoteSpeechProviderPanel: View {
    @Environment(RemoteSpeechInbox.self) private var inbox

    var body: some View {
        VStack(alignment: .leading) {
            Text("Remote Voice provider")
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        guard inbox.receivedEventCount > 0 else {
            return "Waiting for VoiceOver output. Select FarRelay Remote Voice in VoiceOver settings to run the semantic-output spike."
        }
        return "Received \(inbox.receivedEventCount) semantic speech event\(inbox.receivedEventCount == 1 ? "" : "s"). Content is kept out of diagnostics."
    }
}

/// Shown until both the Accessibility and Input Monitoring permissions are
/// granted — without them the keyboard hook can't run.
private struct PermissionsBanner: View {
    @Environment(KeyCapture.self) private var capture

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                if capture.state == .needsAccessibility {
                    Button("Open Accessibility Settings") {
                        Permissions.openAccessibilitySettings()
                    }
                }
                if capture.state == .needsInputMonitoring {
                    Button("Open Input Monitoring Settings") {
                        Permissions.openInputMonitoringSettings()
                    }
                }
                Button("Recheck") { capture.recheck() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.orange.opacity(0.12))
    }

    private var title: String {
        switch capture.state {
        case .needsAccessibility: return "Accessibility permission needed"
        case .needsInputMonitoring: return "Input Monitoring permission needed"
        default: return "Keyboard hook not running"
        }
    }

    private var detail: String {
        switch capture.state {
        case .needsAccessibility:
            return "FarRelay needs Accessibility access to capture and forward keystrokes. Enable FarRelay in System Settings, then click Recheck."
        case .needsInputMonitoring:
            return "FarRelay needs Input Monitoring access to read Caps Lock at the hardware level. Enable FarRelay in System Settings, then click Recheck. You may need to quit and reopen FarRelay."
        default:
            return "The system-wide keyboard hook is stopped."
        }
    }
}

private struct StatusHeader: View {
    @Environment(BridgeClient.self) private var bridge

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(label)
                .bold()
            Spacer()
        }
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(label)")
    }

    private var label: String {
        switch bridge.status {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .authenticating: return "Authenticating"
        case .ready: return "Ready"
        case .nvdaNotConnected: return "Connected, no NVDA on channel"
        case .disconnected(let r): return "Disconnected (\(r))"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    private var color: Color {
        switch bridge.status {
        case .ready: return .green
        case .nvdaNotConnected: return .yellow
        case .connecting, .authenticating: return .orange
        case .failed: return .red
        case .disconnected, .idle: return .secondary
        }
    }
}

private struct ConnectionControls: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge

    var body: some View {
        HStack {
            Button(connectLabel, systemImage: "network") {
                if connected {
                    bridge.stop()
                } else {
                    settings.save()
                    bridge.start(settings)
                }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            SettingsLink {
                Label("Edit Settings", systemImage: "slider.horizontal.3")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var connected: Bool {
        switch bridge.status {
        case .ready, .connecting, .authenticating, .nvdaNotConnected: return true
        default: return false
        }
    }

    private var connectLabel: String { connected ? "Disconnect" : "Connect" }
}

private struct ForwardingPanel: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge
    @Environment(KeyCapture.self) private var capture

    var body: some View {
        @Bindable var bridge = bridge
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Forward keystrokes to slave", isOn: $bridge.forwardingEnabled)
                .toggleStyle(.switch)
                .disabled(bridge.status != .ready && bridge.status != .nvdaNotConnected)
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private var gesture: String {
        settings.nvdaModifier == .capsLock ? "Caps Lock + F11" : "Ctrl + Option + F11"
    }

    private var hint: String {
        guard capture.state == .running else {
            return "Grant the keyboard permissions above to forward keystrokes."
        }
        switch bridge.status {
        case .ready, .nvdaNotConnected:
            return "Press \(gesture) anywhere to toggle forwarding. While on, every key — including ⌘Q and ⌘Tab — goes to the remote NVDA and not this Mac."
        default:
            return "Connect first."
        }
    }
}

private struct LastSpeechPanel: View {
    @Environment(BridgeClient.self) private var bridge

    var body: some View {
        VStack(alignment: .leading) {
            Text("Last spoken")
                .font(.headline)
            Text(bridge.lastSpeech.isEmpty ? "—" : bridge.lastSpeech)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }
}

private struct LogPanel: View {
    @Environment(BridgeClient.self) private var bridge

    var body: some View {
        VStack(alignment: .leading) {
            Text("Log")
                .font(.headline)
                .padding(.horizontal)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(bridge.log.indices, id: \.self) { i in
                        Text(bridge.log[i])
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxHeight: .infinity)
    }
}
