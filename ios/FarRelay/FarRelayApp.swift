import SwiftUI

@main
struct FarRelayApp: App {
    @State private var settings: AppSettings
    @State private var bridge: BridgeClient
    @State private var terminalHost: SSHTerminalHost
    @State private var remoteIntentRouter: RemoteIntentRouter

    init() {
        let s = AppSettings()
        let speech = SpeechOutput(rate: s.speechRate, voiceIdentifier: s.voiceIdentifier)
        let bridge = BridgeClient(speech: speech)
        _settings = State(initialValue: s)
        _bridge = State(initialValue: bridge)
        let terminalHost = SSHTerminalHost()
        let remoteIntentRouter = RemoteIntentRouter()
        remoteIntentRouter.register(NVDARemoteIntentTarget(keySink: bridge))
        remoteIntentRouter.register(TerminalRemoteIntentTarget(presentation: terminalHost.presentation))
        _terminalHost = State(initialValue: terminalHost)
        _remoteIntentRouter = State(initialValue: remoteIntentRouter)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(bridge)
                .environment(terminalHost)
                .environment(remoteIntentRouter)
        }
    }
}
