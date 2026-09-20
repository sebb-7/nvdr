import SwiftUI

struct MacRemoteFeatureView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(MacRemoteSession.self) private var session
    @Environment(RemoteIntentRouter.self) private var router
    let profile: HostProfile

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Host status", value: stateLabel)
                LabeledContent("Remote VoiceOver", value: session.speechSubscriptionActive ? "Subscribed" : "Not subscribed")
                LabeledContent("Keyboard forwarding", value: session.keyboardForwardingActive ? "Active" : "Inactive")
                Button(isConnected ? "Disconnect" : "Connect", systemImage: "network") {
                    if isConnected { session.disconnect() }
                    else if let credentials = settings.credentials(for: profile) {
                        _ = router.setActiveTarget(id: MacRemoteIntentTarget.defaultID)
                        session.connect(profile: profile, credentials: credentials)
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Section("Control") {
                Button("Request Control") { session.requestControl() }
                    .disabled(!isConnected)
                Button("Release Control") { session.releaseControl() }
                    .disabled(!session.keyboardForwardingActive)
                Button("Emergency Stop", role: .destructive) { session.emergencyStop() }
                    .disabled(!isConnected)
            }

            Section("Test keyboard commands") {
                Button("VoiceOver Right") { route(.accessibilityNext) }
                Button("VoiceOver Left") { route(.accessibilityPrevious) }
                Button("VoiceOver Activate") { route(.accessibilityActivate) }
                Button("Command-Tab") { route(.nextApplication) }
                Text("These semantic actions route through the selected Mac target and its controller lease. Hardware-keyboard forwarding is the next validation target; do not treat this UI test as proof of physical keyboard behavior.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(profile.displayName)
    }

    private var isConnected: Bool {
        switch session.state {
        case .disconnected, .failed: false
        case .connecting, .connected, .controlGranted, .controlBusy: true
        }
    }

    private var stateLabel: String {
        switch session.state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .controlGranted: "Control granted"
        case .controlBusy: "Control busy"
        case .failed(let message): "Failed: \(message)"
        }
    }

    private func route(_ intent: RemoteIntent) {
        Task { _ = await router.route(intent) }
    }
}
