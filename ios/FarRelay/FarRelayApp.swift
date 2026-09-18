import SwiftUI

@main
struct FarRelayApp: App {
    @State private var settings: AppSettings
    @State private var bridge: BridgeClient
    @State private var terminals: TerminalSessionManager
    @State private var remoteIntentRouter: RemoteIntentRouter
    @State private var interactionFeedback: InteractionFeedback
    @State private var inputDiagnostics: InputDiagnosticStore
    @State private var macRemoteSession: MacRemoteSession

    init() {
        let s = AppSettings()
        let speech = SpeechOutput(rate: s.speechRate, voiceIdentifier: s.voiceIdentifier)
        let inputDiagnostics = InputDiagnosticStore()
        let bridge = BridgeClient(speech: speech)
        _settings = State(initialValue: s)
        _bridge = State(initialValue: bridge)
        let terminals = TerminalSessionManager()
        let macRemoteSession = MacRemoteSession(speech: speech)
        let remoteIntentRouter = RemoteIntentRouter()
        remoteIntentRouter.register(NVDARemoteIntentTarget(keySink: bridge))
        remoteIntentRouter.register(TerminalRemoteIntentTarget(manager: terminals))
        remoteIntentRouter.register(MacRemoteIntentTarget(controller: macRemoteSession))
        _terminals = State(initialValue: terminals)
        _remoteIntentRouter = State(initialValue: remoteIntentRouter)
        _interactionFeedback = State(initialValue: InteractionFeedback(settings: s))
        _inputDiagnostics = State(initialValue: inputDiagnostics)
        _macRemoteSession = State(initialValue: macRemoteSession)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(bridge)
                .environment(terminals)
                .environment(remoteIntentRouter)
                .environment(interactionFeedback)
                .environment(inputDiagnostics)
                .environment(macRemoteSession)
        }
    }
}
