import SwiftUI

/// Accessible Mac Remote Control screen. Connection logic lives in
/// `MacRemoteControlSession`. This slice does not steal iPhone VoiceOver focus
/// and does not register a RemoteIntent target.
struct MacRemoteControlFeatureView: View {
    @Environment(AppSettings.self) private var settings
    let profile: HostProfile
    @State private var session: MacRemoteControlSession

    init(profile: HostProfile, session: MacRemoteControlSession = MacRemoteControlSession()) {
        self.profile = profile
        _session = State(initialValue: session)
    }

    var body: some View {
        Form {
            Section("Computer") {
                Text(profile.displayName)
                if session.phase.isSessionOpen {
                    Button("Disconnect") {
                        Task { await session.disconnect() }
                    }
                } else {
                    Button("Connect") {
                        Task { await session.connect(settings: settings, profile: profile) }
                    }
                    .disabled(session.phase == .connecting || session.phase == .checkingCapabilities)
                }
            }
            Section("Status") {
                Text(session.statusText)
            }
            Section("VoiceOver status") {
                Text(session.voiceOverStatusText)
            }
            Section("Current") {
                if let phrase = session.lastSpokenPhraseText {
                    Text("Last spoken phrase: \(phrase)")
                }
                if let cursor = session.voiceOverCursorText {
                    Text("VoiceOver cursor: \(cursor)")
                }
                if let keyboard = session.keyboardCursorText {
                    Text("Keyboard cursor: \(keyboard)")
                }
                if !session.hasDisplayedVoiceOverState {
                    Text("VoiceOver state is unavailable.")
                }
            }
            if let error = session.lastActionError {
                Section("Action") {
                    Text(error)
                }
            }
            if let error = session.lastStateRefreshError {
                Section("Feedback") {
                    Text(error)
                }
            }
            Section("Controls") {
                ForEach(MacRemoteControlAction.allCases) { action in
                    Button(action.buttonTitle) {
                        Task { await session.perform(action) }
                    }
                    .disabled(!session.controlsEnabled)
                }
                Text("These controls are provisional and have not been validated on physical Mac hardware.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Remote Control")
        .onDisappear {
            Task { await session.disconnect() }
        }
    }
}
