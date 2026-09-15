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
                Button(connectionAction.title, systemImage: "network") {
                    switch connectionAction {
                    case .connect:
                        bridge.start(settings: settings, profile: profile)
                    case .cancel, .disconnect:
                        bridge.stop()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            Section("Status") { Text(statusLabel) }
            Section("Keyboard forwarding") {
                Toggle("Forward keystrokes to slave", isOn: forwardingBinding).disabled(!isForwardingAvailable)
                Text(isForwardingAvailable ? "Turn this off to use the keyboard locally." : "Connect first.").font(.footnote).foregroundStyle(.secondary)
                if isVoiceOverEnabled, isForwardingAvailable {
                    Text("For arrow-key forwarding, turn VoiceOver Quick Nav off. Press Left Arrow and Right Arrow together to toggle Quick Nav.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

    private var connectionAction: NVDARemoteConnectionAction {
        NVDARemoteConnectionAction(status: bridge.status)
    }
    private var isConnectionActive: Bool {
        return switch bridge.status {
        case .connecting, .authenticating, .reconnecting, .relayConnected, .waitingForNVDA, .ready, .nvdaNotConnected: true
        default: false
        }
    }
    private var isForwardingAvailable: Bool {
        return switch bridge.status { case .ready: true; default: false }
    }
    private var statusLabel: String {
        return switch bridge.status {
        case .idle: "Idle"; case .connecting: "Connecting"; case .authenticating: "Authenticating"; case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))"; case .relayConnected: "Relay connected"; case .waitingForNVDA, .nvdaNotConnected: "Waiting for NVDA"; case .ready: "NVDA connected"; case .disconnected(let reason): "Disconnected (\(reason))"; case .failed(let message): "Failed: \(message)"
        }
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

/// The connection control reflects transport truth, never merely the user's
/// request. A pending connection can be cancelled, but it is not Connected.
enum NVDARemoteConnectionAction: Equatable {
    case connect
    case cancel
    case disconnect

    init(status: BridgeClient.Status) {
        switch status {
        case .idle, .disconnected, .failed:
            self = .connect
        case .connecting, .authenticating, .reconnecting:
            self = .cancel
        case .relayConnected, .waitingForNVDA, .ready, .nvdaNotConnected:
            self = .disconnect
        }
    }

    var title: String {
        switch self {
        case .connect: "Connect"
        case .cancel: "Cancel connection"
        case .disconnect: "Disconnect"
        }
    }
}
