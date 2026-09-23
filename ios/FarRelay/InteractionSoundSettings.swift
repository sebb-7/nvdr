import Foundation
import Observation

/// Device-local preferences for FarRelay-owned earcons. Remote NVDA wave/tone
/// events and RemSound playback do not use this store.
@Observable
@MainActor
final class InteractionSoundSettings {
    private(set) var preferences: InteractionSoundPreferences
    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "farrelay.interactionSoundPreferences"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(InteractionSoundPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = InteractionSoundPreferences()
        }
    }

    func preference(for intent: InteractionSoundIntent) -> InteractionSoundPreference {
        preferences.preference(for: intent)
    }

    func setEnabled(_ enabled: Bool, for intent: InteractionSoundIntent) {
        preferences.setEnabled(enabled, for: intent)
        persist()
    }

    func setFilename(_ filename: String, for intent: InteractionSoundIntent) {
        preferences.setFilename(filename, for: intent)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
