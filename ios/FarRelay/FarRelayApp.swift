import SwiftUI
import UIKit

enum ControllerInputPresentation: String, Identifiable, Sendable {
    case textMode
    case quickCommandMode

    var id: String { rawValue }

    static func active(
        textModeActive: Bool,
        quickCommandModeActive: Bool
    ) -> ControllerInputPresentation? {
        if textModeActive { return .textMode }
        if quickCommandModeActive { return .quickCommandMode }
        return nil
    }
}

@main
struct FarRelayApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings: AppSettings
    @State private var bridge: BridgeClient
    @State private var terminals: TerminalSessionManager
    @State private var remoteIntentRouter: RemoteIntentRouter
    @State private var interactionFeedback: InteractionFeedback
    @State private var interactionSoundSettings: InteractionSoundSettings
    @State private var inputDiagnostics: InputDiagnosticStore
    @State private var macRemoteSession: MacRemoteSession
    @State private var events: FarRelayEventStore
    @State private var controllerMappings: ControllerMappingSettings
    @State private var controllerAdapter: DualSenseControllerAdapter
    @State private var audioReceiver: AudioReceiverModel
    @State private var remSoundOrchestration: RemSoundOrchestrationSession
    @State private var pendingProfileImport: FarRelayControllerProfileManifest?
    @State private var profileImportErrorMessage: String?

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
        let interactionSoundSettings = InteractionSoundSettings()
        _interactionSoundSettings = State(initialValue: interactionSoundSettings)
        let interactionFeedback = InteractionFeedback(settings: s, soundSettings: interactionSoundSettings)
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
        let audioReceiver = AudioReceiverModel()
        _audioReceiver = State(initialValue: audioReceiver)
        _remSoundOrchestration = State(initialValue: RemSoundOrchestrationSession(receiver: audioReceiver))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(bridge)
                .environment(terminals)
                .environment(remoteIntentRouter)
                .environment(interactionFeedback)
                .environment(interactionSoundSettings)
                .environment(inputDiagnostics)
                .environment(macRemoteSession)
                .environment(events)
                .environment(controllerMappings)
                .environment(controllerAdapter)
                .environment(audioReceiver)
                .environment(remSoundOrchestration)
                .task {
                    UIApplication.shared.isIdleTimerDisabled = true
                    controllerAdapter.start()
                }
                .sheet(item: Binding(
                    get: {
                        ControllerInputPresentation.active(
                            textModeActive: controllerAdapter.isTextModeActive,
                            quickCommandModeActive: controllerAdapter.isQuickCommandModeActive
                        )
                    },
                    set: { presentation in
                        guard presentation == nil else { return }
                        if controllerAdapter.isTextModeActive {
                            controllerAdapter.exitTextMode()
                        }
                        if controllerAdapter.isQuickCommandModeActive {
                            controllerAdapter.exitQuickCommandMode()
                        }
                    }
                )) { presentation in
                    switch presentation {
                    case .textMode:
                        TextModeEntryView(controller: controllerAdapter)
                    case .quickCommandMode:
                        QuickCommandEntryView(controller: controllerAdapter)
                    }
                }
                .onOpenURL { url in
                    handleIncomingProfileURL(url)
                }
                .confirmationDialog(
                    "Import Controller Profile",
                    isPresented: Binding(
                        get: { pendingProfileImport != nil },
                        set: { presented in
                            if !presented { pendingProfileImport = nil }
                        }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Import as New Profile") {
                        importPendingProfile()
                    }
                    Button("Cancel", role: .cancel) {
                        pendingProfileImport = nil
                    }
                } message: {
                    Text(pendingProfileImport?.importSummary ?? "")
                }
                .alert(
                    "Profile Could Not Be Imported",
                    isPresented: Binding(
                        get: { profileImportErrorMessage != nil },
                        set: { presented in
                            if !presented { profileImportErrorMessage = nil }
                        }
                    )
                ) {
                    Button("OK", role: .cancel) {
                        profileImportErrorMessage = nil
                    }
                } message: {
                    Text(profileImportErrorMessage ?? "Unknown profile import error.")
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

    private func handleIncomingProfileURL(_ url: URL) {
        guard FarRelayProfileFileImport.canOpen(url) else { return }

        do {
            pendingProfileImport = try FarRelayProfileFileImport.decode(url)
        } catch {
            profileImportErrorMessage = error.localizedDescription
        }
    }

    private func importPendingProfile() {
        guard let manifest = pendingProfileImport else { return }
        pendingProfileImport = nil

        do {
            let importedID = try controllerMappings.importPortableProfile(manifest)
            let name = controllerMappings.profiles.first(where: { $0.id == importedID })?.name
                ?? manifest.profile.name
            AccessibilityNotification.Announcement(
                "Imported \(name) as a new controller profile. It is not active yet."
            ).post()
        } catch {
            profileImportErrorMessage = error.localizedDescription
        }
    }
}
