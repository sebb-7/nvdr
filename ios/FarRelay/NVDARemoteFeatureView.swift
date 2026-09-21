import SwiftUI

struct NVDARemoteFeatureView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge
    @Environment(InteractionFeedback.self) private var interactionFeedback
    @Environment(InputDiagnosticStore.self) private var inputDiagnostics
    @Environment(RemoteIntentRouter.self) private var router
    @Environment(DualSenseControllerAdapter.self) private var controllerAdapter
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    let profile: HostProfile
    @State private var presentedIssue: UserFacingIssue?

    var body: some View {
        @Bindable var diagnostics = inputDiagnostics
        Form {
            Section("Computer") {
                Text(profile.displayName)
                HStack(alignment: .firstTextBaseline) {
                    Button(connectionAction.title, systemImage: "network") {
                        switch connectionAction {
                        case .connect:
                            activateNVDAControlTarget()
                            bridge.start(settings: settings, profile: profile)
                        case .cancel, .disconnect:
                            bridge.stop()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    if let controllerStatus = controllerAdapter.controllerStatus {
                        Text(controllerStatus.compactLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Controller. \(controllerStatus.compactLabel)")
                    }
                }
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
            Section("Input diagnostics") {
                Toggle("Record remote keyboard diagnostics", isOn: $diagnostics.isEnabled)
                Text("Records only key metadata and forwarding results. It never records typed text, credentials, terminal content, or speech.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Copy input diagnostic report", systemImage: "doc.on.doc") {
                    AppClipboard.copy(inputDiagnostics.report(
                        connectionState: statusLabel,
                        hostInputEvidence: bridge.inputTransportDiagnostics
                    ))
                }
                Button("Clear input diagnostics", role: .destructive) {
                    inputDiagnostics.clear()
                }
                .disabled(inputDiagnostics.entries.isEmpty)
                if let last = inputDiagnostics.entries.last {
                    Text("Last event: \(last.reportLine)").font(.footnote.monospaced()).foregroundStyle(.secondary)
                }
            }
            Section("Last spoken") { Text(bridge.lastSpeech.isEmpty ? "—" : bridge.lastSpeech) }
            Section("Log") { ForEach(bridge.log.indices, id: \.self) { Text(bridge.log[$0]).font(.caption.monospaced()) } }
        }
        .navigationTitle("NVDA Remote")
        // The old zero-height overlay could not reliably retain responder
        // ownership on physical keyboards. Keep a real, non-interactive view
        // in the hierarchy while leaving it unavailable to touch and VoiceOver.
        .background {
            KeyboardCapture(bridge: bridge, settings: settings, diagnostics: inputDiagnostics)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                // Recreate the first responder when the condition governing
                // key commands changes. This is the supported SwiftUI/UIKit
                // lifecycle path; UIKit exposes no public cache invalidation
                // API for a UIView's `keyCommands` override.
                .id(bridge.forwardingEnabled)
        }
        .onAppear {
            activateNVDAControlTarget()
            controllerAdapter.refreshControllerStatus()
        }
        .onChange(of: bridge.status) { old, new in
            if old == .ready, new != .ready {
                controllerAdapter.suspendInputForInactiveContext()
            }
            handleStatusChange(from: old, to: new)
        }
        .onChange(of: scenePhase) { _, phase in
            if NVDARemoteSceneLifecyclePolicy.shouldSuspendInput(for: phase) {
                controllerAdapter.suspendInputForInactiveContext()
                bridge.suspendInputForInactiveContext()
            }
        }
        .userFacingIssueAlert($presentedIssue) { _ in
            presentedIssue = nil
            activateNVDAControlTarget()
            bridge.start(settings: settings, profile: profile)
        }
        .onDisappear {
            controllerAdapter.suspendInputForInactiveContext()
            bridge.suspendInputForInactiveContext()
            deactivateNVDAControlTargetIfOwned()
        }
    }

    private func activateNVDAControlTarget() {
        _ = router.setActiveTarget(id: NVDARemoteIntentTarget.defaultID)
    }

    private func deactivateNVDAControlTargetIfOwned() {
        guard router.activeTargetID == NVDARemoteIntentTarget.defaultID else { return }
        _ = router.setActiveTarget(id: nil)
    }

    private var forwardingBinding: Binding<Bool> {
        Binding(
            get: { bridge.forwardingEnabled },
            set: { enabled in
                bridge.forwardingEnabled = enabled
                interactionFeedback.play(enabled ? .keyboardRemote : .keyboardLocal, haptic: .selectionAccepted)
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

/// Scene activation must not manufacture a replacement SSH generation. The
/// supervisor observes real transport loss and reconnects when necessary;
/// backgrounding only removes unsafe keyboard ownership.
enum NVDARemoteSceneLifecyclePolicy {
    static func shouldSuspendInput(for phase: ScenePhase) -> Bool {
        switch phase {
        case .inactive, .background: true
        case .active: false
        @unknown default: true
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
