import SwiftUI

struct NVDARemoteFeatureView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BridgeClient.self) private var bridge
    let profile: HostProfile

    var body: some View {
        @Bindable var bridge = bridge
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
                Toggle("Forward keystrokes to slave", isOn: $bridge.forwardingEnabled).disabled(!isForwardingAvailable)
                Text(isForwardingAvailable ? "Turn this off to use the keyboard locally." : "Connect first.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Last spoken") { Text(bridge.lastSpeech.isEmpty ? "—" : bridge.lastSpeech) }
            Section("Log") { ForEach(bridge.log.indices, id: \.self) { Text(bridge.log[$0]).font(.caption.monospaced()) } }
        }
        .navigationTitle("NVDA Remote")
        .overlay { KeyboardCapture(bridge: bridge, settings: settings).frame(height: 0) }
        .onDisappear { bridge.suspendInputForInactiveContext() }
    }

    private var isConnected: Bool {
        switch bridge.status { case .ready, .connecting, .authenticating, .reconnecting, .nvdaNotConnected: true; default: false }
    }
    private var isForwardingAvailable: Bool {
        switch bridge.status { case .ready, .nvdaNotConnected: true; default: false }
    }
    private var statusLabel: String {
        switch bridge.status {
        case .idle: "Idle"; case .connecting: "Connecting"; case .authenticating: "Authenticating"; case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))"; case .ready: "Ready"; case .nvdaNotConnected: "Connected, no NVDA on channel"; case .disconnected(let reason): "Disconnected (\(reason))"; case .failed(let message): "Failed: \(message)"
        }
    }
}
