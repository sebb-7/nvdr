import Foundation
import Observation

enum NvdaModifier: String, CaseIterable, Identifiable, Sendable {
    case capsLock
    case voKeys
    var id: String { rawValue }
    var label: String { self == .capsLock ? "CapsLock" : "VO keys (Ctrl+Option)" }
}

enum ModifierMapping: String, CaseIterable, Identifiable, Sendable {
    case alt, win, ctrl, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .alt: "Alt"
        case .win: "Windows / GUI"
        case .ctrl: "Ctrl"
        case .none: "Ignore"
        }
    }
}

enum SSHAuthMode: String, CaseIterable, Identifiable, Codable, Equatable, Sendable {
    case password, privateKey
    var id: String { rawValue }
    var label: String { self == .password ? "Password" : "Private key" }
}

@Observable
@MainActor
final class AppSettings {
    var nvdaModifier: NvdaModifier
    var optionMapping: ModifierMapping
    var commandMapping: ModifierMapping
    var speechRate: Float
    var voiceIdentifier: String?
    var hapticFeedbackEnabled: Bool
    var soundCuesEnabled: Bool
    var dynamicReadingEnabled: Bool
    var voiceOverActionPreferences: VoiceOverActionPreferences
    private(set) var terminalControlKeys: [TerminalControlKey]
    private(set) var hostProfiles: [HostProfile] = []
    private(set) var credentialStorageError: String? = nil

    private let defaults: UserDefaults
    private let profileCredentialPersistence: HostProfileCredentialPersistence
    private let terminalControlKeyStore: TerminalControlKeyStore
    private let profileStore: HostProfileStore

    init(
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStore = KeychainCredentialStore()
    ) {
        self.defaults = defaults
        profileCredentialPersistence = HostProfileCredentialPersistence(store: credentialStore)
        terminalControlKeyStore = TerminalControlKeyStore(defaults: defaults, key: Keys.terminalControlKeys)
        profileStore = HostProfileStore(defaults: defaults, key: Keys.hostProfiles)
        nvdaModifier = NvdaModifier(rawValue: defaults.string(forKey: Keys.nvdaModifier) ?? "") ?? .capsLock
        optionMapping = ModifierMapping(rawValue: defaults.string(forKey: Keys.optionMapping) ?? "") ?? .win
        commandMapping = ModifierMapping(rawValue: defaults.string(forKey: Keys.commandMapping) ?? "") ?? .win
        speechRate = Float(defaults.object(forKey: Keys.speechRate) as? Double ?? 0.55)
        voiceIdentifier = defaults.string(forKey: Keys.voiceIdentifier)
        hapticFeedbackEnabled = defaults.object(forKey: Keys.hapticFeedbackEnabled) as? Bool ?? true
        soundCuesEnabled = defaults.object(forKey: Keys.soundCuesEnabled) as? Bool ?? false
        dynamicReadingEnabled = defaults.object(forKey: Keys.dynamicReadingEnabled) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.voiceOverActionPreferences),
           let stored = try? JSONDecoder().decode(VoiceOverActionPreferences.self, from: data) {
            voiceOverActionPreferences = stored
        } else {
            voiceOverActionPreferences = .defaults
        }
        switch terminalControlKeyStore.load() {
        case .uninitialized:
            terminalControlKeys = TerminalControlKey.defaultControls
            terminalControlKeyStore.save(terminalControlKeys)
        case .controls(let controls): terminalControlKeys = controls
        case .malformed:
            terminalControlKeys = []
            terminalControlKeyStore.save([])
        }

        switch profileStore.load() {
        case .profiles(let profiles): hostProfiles = profiles
        case .malformed:
            hostProfiles = []
            // Keep the original bytes intact. Overwriting a malformed record
            // with an empty array turns a recoverable corruption into data
            // loss before the user can restore from a backup or later build.
            credentialStorageError = "Saved computer metadata was unreadable and was preserved for recovery."
        case .uninitialized:
            hostProfiles = []
            migrateSingleComputerSettings()
        }
        migrateLegacyNVDARemoteConfiguration()
    }

    func save() {
        defaults.set(nvdaModifier.rawValue, forKey: Keys.nvdaModifier)
        defaults.set(optionMapping.rawValue, forKey: Keys.optionMapping)
        defaults.set(commandMapping.rawValue, forKey: Keys.commandMapping)
        defaults.set(Double(speechRate), forKey: Keys.speechRate)
        if let voiceIdentifier { defaults.set(voiceIdentifier, forKey: Keys.voiceIdentifier) }
        else { defaults.removeObject(forKey: Keys.voiceIdentifier) }
        defaults.set(hapticFeedbackEnabled, forKey: Keys.hapticFeedbackEnabled)
        defaults.set(soundCuesEnabled, forKey: Keys.soundCuesEnabled)
        defaults.set(dynamicReadingEnabled, forKey: Keys.dynamicReadingEnabled)
        if let data = try? JSONEncoder().encode(voiceOverActionPreferences) {
            defaults.set(data, forKey: Keys.voiceOverActionPreferences)
        }
        terminalControlKeyStore.save(terminalControlKeys)
    }

    @discardableResult
    func saveProfile(_ profile: HostProfile, credentials: HostProfileCredentials) -> Bool {
        var normalizedProfile = profile
        normalizedProfile.nvdaRemote = profile.nvdaRemote?.normalized()
        guard case .success = profileCredentialPersistence.save(credentials, for: normalizedProfile.id) else {
            credentialStorageError = "Unable to save credentials for \(profile.displayName)."
            return false
        }
        if let index = hostProfiles.firstIndex(where: { $0.id == normalizedProfile.id }) { hostProfiles[index] = normalizedProfile }
        else { hostProfiles.append(normalizedProfile) }
        profileStore.save(hostProfiles)
        credentialStorageError = nil
        return true
    }

    @discardableResult
    func deleteProfile(_ profile: HostProfile) -> Bool {
        guard case .success = profileCredentialPersistence.deleteCredentials(for: profile.id) else {
            credentialStorageError = "Unable to remove credentials for \(profile.displayName)."
            return false
        }
        hostProfiles.removeAll { $0.id == profile.id }
        profileStore.save(hostProfiles)
        credentialStorageError = nil
        return true
    }

    func credentials(for profile: HostProfile) -> HostProfileCredentials? {
        switch profileCredentialPersistence.load(for: profile.id) {
        case .success(let credentials): return credentials
        case .failure:
            credentialStorageError = "Unable to load credentials for \(profile.displayName)."
            return nil
        }
    }

    func sshSessionConfiguration(for profile: HostProfile) -> SSHSessionConfiguration? {
        guard profile.isConnectionReady, let credentials = credentials(for: profile) else { return nil }
        return profile.sshSessionConfiguration(credentials: credentials)
    }

    /// This is deliberately the legacy NVDA IPC command. `farrelay-host` is a
    /// distinct structured host protocol command stored on HostProfile.
    func nvdaBridgeCommand(for profile: HostProfile) -> String? {
        guard profile.isNVDARemoteEnabled, let capability = profile.nvdaRemote?.normalized() else { return nil }
        var command = profile.nvdaBridgeCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.isEmpty { command = "farrelay" }
        var argv = [command, "--ipc", "--host", capability.relayHost, "--port", String(capability.relayPort), "--channel", capability.channel]
        if !capability.fingerprint.isEmpty { argv += ["--fingerprint", capability.fingerprint] }
        if capability.insecure { argv.append("--insecure") }
        return argv.map(shellQuote).joined(separator: " ")
    }

    @discardableResult
    func replaceTerminalControlKeys(_ controls: [TerminalControlKey]) -> Bool {
        guard Set(controls.map(\.id)).count == controls.count,
              controls.allSatisfy({ $0.validationError(among: controls) == nil }) else { return false }
        terminalControlKeys = controls
        terminalControlKeyStore.save(controls)
        return true
    }

    func restoreDefaultTerminalControlKeys() { _ = replaceTerminalControlKeys(TerminalControlKey.defaultControls) }

    private func migrateSingleComputerSettings() {
        let address = defaults.string(forKey: Keys.legacySSHHost) ?? ""
        let username = defaults.string(forKey: Keys.legacySSHUser) ?? ""
        guard !address.isEmpty || !username.isEmpty else { profileStore.save([]); return }
        let profile = HostProfile(
            displayName: "Imported Computer",
            address: address,
            port: defaults.object(forKey: Keys.legacySSHPort) as? Int ?? 22,
            username: username,
            authenticationMode: SSHAuthMode(rawValue: defaults.string(forKey: Keys.legacySSHAuthMode) ?? "") ?? .password,
            platform: legacyNVDARemoteCapability() == nil ? .other : .windows,
            farRelayHostCommand: "farrelay-host",
            nvdaBridgeCommand: defaults.string(forKey: Keys.legacyRemoteCommand) ?? "farrelay",
            nvdaRemote: legacyNVDARemoteCapability()
        )
        switch profileCredentialPersistence.migrateLegacyCredentials(to: profile.id, defaults: defaults) {
        case .success:
            hostProfiles = [profile]
            profileStore.save(hostProfiles)
            [Keys.legacySSHHost, Keys.legacySSHPort, Keys.legacySSHUser,
             Keys.legacySSHAuthMode, Keys.legacyRemoteCommand].forEach(defaults.removeObject(forKey:))
        case .failure(let error):
            credentialStorageError = "Unable to migrate the imported computer credentials: \(error.localizedDescription)"
        }
    }

    private func migrateLegacyNVDARemoteConfiguration() {
        guard !defaults.bool(forKey: Keys.nvdaCapabilityMigrationComplete) else { return }
        guard let capability = legacyNVDARemoteCapability() else {
            clearLegacyNVDARemoteKeys()
            defaults.set(true, forKey: Keys.nvdaCapabilityMigrationComplete)
            return
        }
        let selectedID = UUID(uuidString: defaults.string(forKey: Keys.legacySelectedNVDAProfileID) ?? "")
        guard let index = hostProfiles.firstIndex(where: { $0.id == selectedID }) ?? hostProfiles.indices.first else { return }
        if hostProfiles[index].nvdaRemote == nil {
            hostProfiles[index].nvdaRemote = capability
            hostProfiles[index].platform = .windows
            profileStore.save(hostProfiles)
        }
        clearLegacyNVDARemoteKeys()
        defaults.set(true, forKey: Keys.nvdaCapabilityMigrationComplete)
    }

    /// An empty legacy channel means NVDA Remote was never actually configured.
    /// Default relay host/port alone must not create or enable a capability.
    private func legacyNVDARemoteCapability() -> NVDARemoteCapability? {
        let keys = [Keys.legacyRelayHost, Keys.legacyRelayPort, Keys.legacyChannel, Keys.legacyFingerprint, Keys.legacyInsecure]
        guard keys.contains(where: { defaults.object(forKey: $0) != nil }) else { return nil }
        let channel = defaults.string(forKey: Keys.legacyChannel) ?? ""
        guard !channel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NVDARemoteCapability(
            isEnabled: true,
            relayHost: defaults.string(forKey: Keys.legacyRelayHost) ?? "nvdaremote.com",
            relayPort: defaults.object(forKey: Keys.legacyRelayPort) as? Int ?? 6837,
            channel: channel,
            fingerprint: defaults.string(forKey: Keys.legacyFingerprint) ?? "",
            insecure: defaults.bool(forKey: Keys.legacyInsecure)
        )
    }

    private func clearLegacyNVDARemoteKeys() {
        [Keys.legacyRelayHost, Keys.legacyRelayPort, Keys.legacyChannel, Keys.legacyFingerprint,
         Keys.legacyInsecure, Keys.legacySelectedNVDAProfileID].forEach(defaults.removeObject(forKey:))
    }

    private enum Keys {
        static let hostProfiles = "farrelay.hostProfiles"
        static let nvdaCapabilityMigrationComplete = "farrelay.nvdaCapabilityMigrationComplete"
        static let legacySelectedNVDAProfileID = "farrelay.selectedNVDAProfileID"
        static let legacyRelayHost = "farrelay.relayHost"
        static let legacyRelayPort = "farrelay.relayPort"
        static let legacyChannel = "farrelay.channel"
        static let legacyFingerprint = "farrelay.fingerprint"
        static let legacyInsecure = "farrelay.insecure"
        static let nvdaModifier = "farrelay.nvdaModifier"
        static let optionMapping = "farrelay.optionMapping"
        static let commandMapping = "farrelay.commandMapping"
        static let speechRate = "farrelay.speechRate"
        static let voiceIdentifier = "farrelay.voiceIdentifier"
        static let hapticFeedbackEnabled = "farrelay.hapticFeedbackEnabled"
        static let soundCuesEnabled = "farrelay.soundCuesEnabled"
        static let dynamicReadingEnabled = "farrelay.dynamicReadingEnabled"
        static let voiceOverActionPreferences = "farrelay.voiceOverActionPreferences"
        static let terminalControlKeys = "farrelay.terminalControlKeys"
        static let legacySSHHost = "farrelay.sshHost"
        static let legacySSHPort = "farrelay.sshPort"
        static let legacySSHUser = "farrelay.sshUser"
        static let legacySSHAuthMode = "farrelay.sshAuthMode"
        static let legacyRemoteCommand = "farrelay.remoteCommand"
    }
}

private func shellQuote(_ value: String) -> String {
    if value.isEmpty { return "''" }
    if value.allSatisfy({ $0.isLetter || $0.isNumber || "@%+=:,./-_".contains($0) }) { return value }
    return "'" + value.replacing("'", with: "'\\''") + "'"
}
