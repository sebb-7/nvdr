import XCTest
@testable import FarRelay

@MainActor
final class SoundIntentTests: XCTestCase {
    func testSemanticIntentMapsToCanonicalFilenames() {
        XCTAssertEqual(InteractionSoundIntent.remoteConnected.filename, "connected.wav")
        XCTAssertEqual(InteractionSoundIntent.keyboardRemote.filename, "keyboard-remote.wav")
        XCTAssertEqual(InteractionSoundIntent.copied.filename, "copied.wav")
        XCTAssertEqual(InteractionSoundIntent.layerExit.filename, "action.wav")
        XCTAssertNotEqual(InteractionSoundIntent.layerExit.filename, InteractionSoundIntent.nvdaStopped.filename)
    }

    func testEveryDefaultSoundIsInTheSelectableCatalog() {
        for intent in InteractionSoundIntent.allCases {
            XCTAssertTrue(
                AppSoundCatalog.contains(filename: intent.defaultFilename),
                "Default sound for \(intent.rawValue) is not selectable: \(intent.defaultFilename)"
            )
        }
    }

    func testDisablingOneAppSoundEventDoesNotSuppressOtherEvents() {
        var preferences = InteractionSoundPreferences()
        preferences.setEnabled(false, for: .action)

        XCTAssertFalse(preferences.preference(for: .action).isEnabled)
        XCTAssertTrue(preferences.preference(for: .success).isEnabled)
        XCTAssertEqual(
            preferences.preference(for: .success).filename,
            InteractionSoundIntent.success.defaultFilename
        )
    }

    func testSelectingAnAppSoundChangesOnlyThatSemanticEvent() {
        var preferences = InteractionSoundPreferences()
        let originalSuccess = preferences.preference(for: .success)
        preferences.setFilename("warning.wav", for: .action)

        XCTAssertEqual(preferences.preference(for: .action).filename, "warning.wav")
        XCTAssertEqual(preferences.preference(for: .success), originalSuccess)
    }

    func testGlobalSoundCuesIsTheMasterForAppOwnedEventsOnly() throws {
        let suiteName = "SoundIntentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults, credentialStore: SoundIntentCredentialStore())
        let soundSettings = InteractionSoundSettings(defaults: defaults, storageKey: "sound-intents")
        let feedback = InteractionFeedback(settings: settings, soundSettings: soundSettings)

        settings.soundCuesEnabled = false
        XCTAssertFalse(feedback.canPlayConfiguredSound(.action))
        settings.soundCuesEnabled = true
        XCTAssertTrue(feedback.canPlayConfiguredSound(.action))
        soundSettings.setEnabled(false, for: .action)
        XCTAssertFalse(feedback.canPlayConfiguredSound(.action))

        // NVDA wave/tone events originate in IPC and are intentionally absent
        // from this app-owned preference catalog.
        XCTAssertFalse(InteractionSoundIntent.allCases.map(\.rawValue).contains("wave"))
        XCTAssertFalse(InteractionSoundIntent.allCases.map(\.rawValue).contains("tone"))
    }

    func testCanonicalSoundResourcesResolveFromBuiltAppBundle() {
        let filenames = [
            "connected.wav", "disconnected.wav",
            "keyboard-remote.wav", "keyboard-local.wav",
            "terminal-open.wav", "push_clipboard.wav",
            "receive_clipboard.wav", "nvda-started.wav",
            "nvda-stopped.wav", "action.wav", "success.wav",
            "warning.wav", "error.wav", "copied.wav", "exit.wav",
            "browseMode.wav", "focusMode.wav"
        ]

        for filename in filenames {
            XCTAssertNotNil(
                SoundResourceResolver.bundledURL(for: filename, in: .main),
                "Missing bundled sound resource: \(filename)"
            )
        }
    }

    func testRemoteWaveLookupIsGenericAndSafe() {
        XCTAssertEqual(SoundResourceResolver.remoteWaveFilename(from: "C:\\Program Files\\NVDA\\waves\\browseMode.wav"), "browseMode.wav")
        XCTAssertEqual(SoundResourceResolver.remoteWaveFilename(from: "/usr/share/nvda/waves/focusMode.wav"), "focusMode.wav")
        XCTAssertEqual(SoundResourceResolver.remoteWaveFilename(from: "otherCue.WAV"), "otherCue.WAV")
        XCTAssertNil(SoundResourceResolver.remoteWaveFilename(from: "../../outside.wav"))
        XCTAssertNil(SoundResourceResolver.bundledURL(for: "missing.wav", in: .main))
    }

    func testIPCParsesRemoteSoundEventsAndFailsClosed() {
        guard let tone = RemoteNVDATone(frequency: 440, durationMilliseconds: 100, leftLevel: 50, rightLevel: 50) else {
            return XCTFail("fixture tone should be valid")
        }
        XCTAssertEqual(IPCParser.parse("tone 440 100 50 50"), .tone(tone))
        XCTAssertEqual(IPCParser.parse("wave browseMode.wav"), .wave("browseMode.wav"))
        if case .unknown = IPCParser.parse("tone 440 nope 50 50") {} else { XCTFail("malformed tone must fail closed") }
        if case .unknown = IPCParser.parse("wave ../outside.wav") {} else { XCTFail("unsafe wave must fail closed") }
    }

    func testConnectionAndKeyboardCuesAreTransitionSpecific() {
        XCTAssertEqual(BridgeClient.soundIntent(from: .connecting, to: .ready), .remoteConnected)
        XCTAssertNil(BridgeClient.soundIntent(from: .ready, to: .ready))
        XCTAssertEqual(BridgeClient.soundIntent(from: .ready, to: .waitingForNVDA), .nvdaStopped)
        XCTAssertEqual(BridgeClient.soundIntent(from: .ready, to: .nvdaNotConnected), .nvdaStopped)
        XCTAssertEqual(BridgeClient.soundIntent(from: .waitingForNVDA, to: .ready), .remoteConnected)
        XCTAssertEqual(
            BridgeClient.soundIntent(
                from: .waitingForNVDA,
                to: .ready,
                nvdaLifecycleInterrupted: true
            ),
            .nvdaStarted
        )
        XCTAssertEqual(
            BridgeClient.soundIntent(
                from: .nvdaNotConnected,
                to: .ready,
                nvdaLifecycleInterrupted: true
            ),
            .nvdaStarted
        )
        XCTAssertEqual(BridgeClient.soundIntent(from: .ready, to: .disconnected(reason: "relay")), .disconnected)
        XCTAssertNil(BridgeClient.soundIntent(from: .failed(message: "no"), to: .disconnected(reason: "relay")))
        XCTAssertNotEqual(InteractionSoundIntent.keyboardRemote, .keyboardLocal)
    }
}

private final class SoundIntentCredentialStore: CredentialStore {
    func string(for account: String) throws -> String? { nil }
    func store(_ value: String, for account: String) throws {}
    func removeValue(for account: String) throws {}
}
