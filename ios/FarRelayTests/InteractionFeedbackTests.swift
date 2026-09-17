import XCTest
@testable import FarRelay

@MainActor
final class InteractionFeedbackTests: XCTestCase {
    func testLegacySettingsDefaultHapticsOnAndSoundCuesOff() throws {
        let settings = try makeSettings()
        XCTAssertTrue(settings.hapticFeedbackEnabled)
        XCTAssertFalse(settings.soundCuesEnabled)
    }

    func testHapticAndSoundSettingsPersistIndependently() throws {
        let defaults = try makeDefaults()
        let store = EmptyFeedbackCredentialStore()
        let settings = AppSettings(defaults: defaults, credentialStore: store)
        settings.hapticFeedbackEnabled = false
        settings.soundCuesEnabled = true
        settings.save()

        let reloaded = AppSettings(defaults: defaults, credentialStore: store)
        XCTAssertFalse(reloaded.hapticFeedbackEnabled)
        XCTAssertTrue(reloaded.soundCuesEnabled)

        reloaded.hapticFeedbackEnabled = true
        reloaded.soundCuesEnabled = false
        reloaded.save()
        let restored = AppSettings(defaults: defaults, credentialStore: store)
        XCTAssertTrue(restored.hapticFeedbackEnabled)
        XCTAssertFalse(restored.soundCuesEnabled)
    }

    func testSemanticFeedbackEventsMapToExpectedCategories() {
        XCTAssertEqual(InteractionFeedbackKind.selectionAccepted.category, .selection)
        XCTAssertEqual(InteractionFeedbackKind.success.category, .success)
        XCTAssertEqual(InteractionFeedbackKind.copied.category, .success)
        XCTAssertEqual(InteractionFeedbackKind.warning.category, .warning)
        XCTAssertEqual(InteractionFeedbackKind.error.category, .error)
    }

    func testPlayRecordsRequestAndRespectsSoundPreference() throws {
        let settings = try makeSettings()
        let feedback = InteractionFeedback(settings: settings)
        settings.soundCuesEnabled = false
        feedback.play(.selectionAccepted)
        XCTAssertEqual(feedback.lastRequest?.kind, .selectionAccepted)
        settings.soundCuesEnabled = true
        feedback.play(.error)
        XCTAssertEqual(feedback.lastRequest?.kind, .error)
        XCTAssertEqual(feedback.lastRequest?.kind.category, .error)
    }

    private func makeSettings() throws -> AppSettings {
        AppSettings(defaults: try makeDefaults(), credentialStore: EmptyFeedbackCredentialStore())
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "InteractionFeedbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}

private final class EmptyFeedbackCredentialStore: CredentialStore {
    func string(for account: String) throws -> String? { nil }
    func store(_ value: String, for account: String) throws {}
    func removeValue(for account: String) throws {}
}
