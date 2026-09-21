import SwiftUI
import UIKit

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
        let interactionFeedback = InteractionFeedback(settings: s)
        _interactionFeedback = State(initialValue: interactionFeedback)
        _inputDiagnostics = State(initialValue: inputDiagnostics)
        _macRemoteSession = State(initialValue: macRemoteSession)
        _events = State(initialValue: events)
        let controllerMappings = ControllerMappingSettings()
        _controllerMappings = State(initialValue: controllerMappings)
        _controllerAdapter = State(initialValue: DualSenseControllerAdapter(
            mappings: controllerMappings,
            settings: s,
            router: remoteIntentRouter,
            diagnostics: inputDiagnostics,
            feedback: interactionFeedback
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
                .task {
                    UIApplication.shared.isIdleTimerDisabled = true
                    controllerAdapter.start()
                }
                .sheet(isPresented: Binding(
                    get: { controllerAdapter.isTextModeActive },
                    set: { if !$0 { controllerAdapter.exitTextMode() } }
                )) {
                    TextModeEntryView(controller: controllerAdapter)
                }
                .sheet(isPresented: Binding(
                    get: { controllerAdapter.isQuickCommandModeActive },
                    set: { if !$0 { controllerAdapter.exitQuickCommandMode() } }
                )) {
                    QuickCommandEntryView(controller: controllerAdapter)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        // FarRelay is an always-on remote-control surface.
                        // Prevent iOS from auto-locking while the app is active;
                        // the user can still lock the device explicitly.
                        UIApplication.shared.isIdleTimerDisabled = true
                        controllerAdapter.start()
                    } else {
                        UIApplication.shared.isIdleTimerDisabled = false
                        controllerAdapter.stop()
                    }
                }
        }
    }
}
