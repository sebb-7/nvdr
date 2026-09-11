import SwiftUI

@main
struct NvdrApp: App {
    @State private var settings: AppSettings
    @State private var bridge: BridgeClient
    @State private var terminalHost: SSHTerminalHost

    init() {
        let s = AppSettings()
        let speech = SpeechOutput(rate: s.speechRate, voiceIdentifier: s.voiceIdentifier)
        _settings = State(initialValue: s)
        _bridge = State(initialValue: BridgeClient(speech: speech))
        _terminalHost = State(initialValue: SSHTerminalHost())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(bridge)
                .environment(terminalHost)
        }
    }
}
