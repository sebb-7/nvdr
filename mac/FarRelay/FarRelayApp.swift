import SwiftUI

@main
struct FarRelayApp: App {
    @State private var settings: AppSettings
    @State private var bridge: BridgeClient
    @State private var capture: KeyCapture
    @State private var remoteSpeechInbox: RemoteSpeechInbox

    init() {
        let settings = AppSettings()
        let speech = SpeechOutput(rate: settings.speechRate, voiceIdentifier: settings.voiceIdentifier)
        let bridge = BridgeClient(speech: speech)
        _settings = State(initialValue: settings)
        _bridge = State(initialValue: bridge)
        _capture = State(initialValue: KeyCapture(bridge: bridge, settings: settings))
        _remoteSpeechInbox = State(initialValue: RemoteSpeechInbox())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(bridge)
                .environment(capture)
                .environment(remoteSpeechInbox)
                .task {
                    capture.start()
                    remoteSpeechInbox.start()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            // Native menu-bar command. The global capslock+F11 hook works
            // regardless of focus; this is the discoverable in-app twin.
            CommandGroup(after: .appInfo) {
                Button("Toggle Keystroke Forwarding") {
                    capture.toggleForwarding()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        // Standard macOS Settings scene — opens with ⌘, and the app menu.
        Settings {
            SettingsView()
                .environment(settings)
                .environment(bridge)
        }
    }
}
