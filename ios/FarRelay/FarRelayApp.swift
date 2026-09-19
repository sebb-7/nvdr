import SwiftUI

@main
struct FarRelayApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings: AppSettings
    @State private var bridge: BridgeClient
    @State private var terminals: TerminalSessionManager
    @State private var remoteIntentRouter: RemoteIntentRouter
    @State private var interactionFeedback: InteractionFeedback
    @State private var inputDiagnostics: InputDiagnosticStore
    @State private var macRemoteSession: MacRemoteSession
    @State private var events: FarRelayEventStore
    @State private var controllerMappings: ControllerMappingSettings
    @State private var controllerAdapter: DualSenseControllerAdapter

    init() {
        let s = AppSettings()
        let speech = SpeechOutput(rate: s.speechRate, voiceIdentifier: s.voiceIdentifier)
        let inputDiagnostics = InputDiagnosticStore()
        let events = FarRelayEventStore()
        let bridge = BridgeClient(speech: speech, events: events)
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
        _events = State(initialValue: events)
        let controllerMappings = ControllerMappingSettings()
        _controllerMappings = State(initialValue: controllerMappings)
        _controllerAdapter = State(initialValue: DualSenseControllerAdapter(
            mappings: controllerMappings,
            settings: s,
            router: remoteIntentRouter,
            diagnostics: inputDiagnostics
        ))
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
                .environment(events)
                .environment(controllerMappings)
                .environment(controllerAdapter)
                .task { controllerAdapter.start() }
                .sheet(isPresented: Binding(
                    get: { controllerAdapter.isTextModeActive },
                    set: { if !$0 { controllerAdapter.exitTextMode() } }
                )) {
                    TextModeEntryView(controller: controllerAdapter)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { controllerAdapter.start() }
                    else { controllerAdapter.stop() }
                }
        }
    }
}
