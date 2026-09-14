import SwiftUI

struct NVDARemoteFeatureView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge
    @Environment(InteractionFeedback.self) private var interactionFeedback
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    let profile: HostProfile
    @State private var presentedIssue: UserFacingIssue?
    @State private var reconnectAfterForeground = false

    var body: some View {
        Form {
            Section("Computer") {
                Text(profile.displayName)
                Button(isConnected ? "Disconnect" : "Connect", systemImage: "network") {
                    if isConnected { bridge.stop() } else { bridge.start(settings: settings, profile: profile) }
                }
                .buttonStyle(.borderedProminent)
            }
            Section("Status") { Text(statusLabel) }
            Section("Keyboard forwarding") {
                Toggle("Forward keystrokes to slave", isOn: forwardingBinding).disabled(!isForwardingAvailable)
                Text(isForwardingAvailable ? "Turn this off to use the keyboard locally." : "Connect first.").font(.footnote).foregroundStyle(.secondary)
            }
            if isVoiceOverEnabled, isForwardingAvailable {
                Section("VoiceOver keyboard fallback") {
                    Text("VoiceOver may keep arrows and Escape for its own navigation. Use these controls when a hardware key is intercepted.")
                        .font(.footnote)
                    HStack {
                        remoteKeyButton("Left", systemImage: "arrow.left", vk: VK.left)
                        remoteKeyButton("Up", systemImage: "arrow.up", vk: VK.up)
                        remoteKeyButton("Down", systemImage: "arrow.down", vk: VK.down)
                        remoteKeyButton("Right", systemImage: "arrow.right", vk: VK.right)
                    }
                    Button("Escape", systemImage: "escape") {
                        sendRemoteTap(VK.escape)
                    }
                    .accessibilityIdentifier("remote-escape-fallback")
                }
            }
            Section("Last spoken") { Text(bridge.lastSpeech.isEmpty ? "—" : bridge.lastSpeech) }
            Section("Log") { ForEach(bridge.log.indices, id: \.self) { Text(bridge.log[$0]).font(.caption.monospaced()) } }
        }
        .navigationTitle("NVDA Remote")
        .overlay { KeyboardCapture(bridge: bridge, settings: settings).frame(height: 0) }
        .onChange(of: bridge.status) { old, new in
            handleStatusChange(from: old, to: new)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive, .background:
                reconnectAfterForeground = isConnectionActive
                bridge.suspendInputForInactiveContext()
            case .active where reconnectAfterForeground:
                reconnectAfterForeground = false
                bridge.start(settings: settings, profile: profile)
            default:
                break
            }
        }
        .userFacingIssueAlert($presentedIssue) { _ in
            presentedIssue = nil
            bridge.start(settings: settings, profile: profile)
        }
        .onDisappear { bridge.suspendInputForInactiveContext() }
    }

    private var forwardingBinding: Binding<Bool> {
        Binding(
            get: { bridge.forwardingEnabled },
            set: { enabled in
                bridge.forwardingEnabled = enabled
                interactionFeedback.play(.selectionAccepted)
                if isVoiceOverEnabled {
                    AccessibilityNotification.Announcement(
                        NVDAForwardingAnnouncementPolicy.announcement(forEnabled: enabled)
                    ).post()
                }
            }
        )
    }

    private var isConnected: Bool {
        switch bridge.status { case .ready, .connecting, .authenticating, .reconnecting, .nvdaNotConnected: true; default: false }
    }
    private var isConnectionActive: Bool {
        switch bridge.status {
        case .connecting, .authenticating, .reconnecting, .ready, .nvdaNotConnected: true
        default: false
        }
    }
    private var isForwardingAvailable: Bool {
        switch bridge.status { case .ready, .nvdaNotConnected: true; default: false }
    }
    private var statusLabel: String {
        switch bridge.status {
        case .idle: "Idle"; case .connecting: "Connecting"; case .authenticating: "Authenticating"; case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))"; case .ready: "Ready"; case .nvdaNotConnected: "Connected, no NVDA on channel"; case .disconnected(let reason): "Disconnected (\(reason))"; case .failed(let message): "Failed: \(message)"
        }
    }

    private func remoteKeyButton(_ label: String, systemImage: String, vk: UInt16) -> some View {
        Button(label, systemImage: systemImage) {
            sendRemoteTap(vk)
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel(label)
        .accessibilityIdentifier("remote-\(label.lowercased())-fallback")
    }

    private func sendRemoteTap(_ vk: UInt16) {
        bridge.sendKey(vk: vk, pressed: true)
        bridge.sendKey(vk: vk, pressed: false)
    }

    private func handleStatusChange(from old: BridgeClient.Status, to new: BridgeClient.Status) {
        if isVoiceOverEnabled,
           let text = ConnectionAnnouncementPolicy.nvdaAnnouncement(
            from: old,
            to: new,
            computerName: profile.displayName
           ) {
            AccessibilityNotification.Announcement(text).post()
        }
        switch new {
        case .ready:
            interactionFeedback.play(.success)
        case .failed(let message):
            interactionFeedback.play(.error)
            presentedIssue = RemoteLaunchDiagnostics.nvdaFailureIssue(
                computerName: profile.displayName,
                reason: message,
                diagnosticText: RemoteLaunchDiagnostics.diagnosticText(
                    computerName: profile.displayName,
                    address: profile.address,
                    port: profile.port,
                    username: profile.username,
                    reason: message,
                    logLines: bridge.log
                ),
                command: profile.nvdaBridgeCommand
            )
        default:
            break
        }
    }
}
