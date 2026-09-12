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
    // Relay settings describe the shared NVDA relay, not one SSH computer.
    var relayHost: String
    var relayPort: Int
    var channel: String
    var fingerprint: String
    var insecure: Bool
    var nvdaModifier: NvdaModifier
    var optionMapping: ModifierMapping
    var commandMapping: ModifierMapping
    var speechRate: Float
    var voiceIdentifier: String?
    private(set) var terminalControlKeys: [TerminalControlKey]
    private(set) var hostProfiles: [HostProfile]
    var selectedNVDAProfileID: UUID? { didSet { saveSelectedNVDAProfileID() } }
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
        relayHost = defaults.string(forKey: Keys.relayHost) ?? "nvdaremote.com"
        relayPort = defaults.object(forKey: Keys.relayPort) as? Int ?? 6837
        channel = defaults.string(forKey: Keys.channel) ?? ""
        fingerprint = defaults.string(forKey: Keys.fingerprint) ?? ""
        insecure = defaults.bool(forKey: Keys.insecure)
        nvdaModifier = NvdaModifier(rawValue: defaults.string(forKey: Keys.nvdaModifier) ?? "") ?? .capsLock
        optionMapping = ModifierMapping(rawValue: defaults.string(forKey: Keys.optionMapping) ?? "") ?? .win
        commandMapping = ModifierMapping(rawValue: defaults.string(forKey: Keys.commandMapping) ?? "") ?? .alt
        speechRate = Float(defaults.object(forKey: Keys.speechRate) as? Double ?? 0.55)
        voiceIdentifier = defaults.string(forKey: Keys.voiceIdentifier)
        selectedNVDAProfileID = UUID(uuidString: defaults.string(forKey: Keys.selectedNVDAProfileID) ?? "")
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
            profileStore.save([])
            credentialStorageError = "Saved computer metadata was unreadable and was reset."
        case .uninitialized:
            hostProfiles = []
            migrateSingleComputerSettings()
        }
        if selectedNVDAProfile == nil { selectedNVDAProfileID = hostProfiles.first?.id }
    }

    var selectedNVDAProfile: HostProfile? {
        hostProfiles.first { $0.id == selectedNVDAProfileID }
    }

    func save() {
        defaults.set(relayHost, forKey: Keys.relayHost)
        defaults.set(relayPort, forKey: Keys.relayPort)
        defaults.set(channel, forKey: Keys.channel)
        defaults.set(fingerprint, forKey: Keys.fingerprint)
        defaults.set(insecure, forKey: Keys.insecure)
        defaults.set(nvdaModifier.rawValue, forKey: Keys.nvdaModifier)
        defaults.set(optionMapping.rawValue, forKey: Keys.optionMapping)
        defaults.set(commandMapping.rawValue, forKey: Keys.commandMapping)
        defaults.set(Double(speechRate), forKey: Keys.speechRate)
        if let voiceIdentifier { defaults.set(voiceIdentifier, forKey: Keys.voiceIdentifier) }
        else { defaults.removeObject(forKey: Keys.voiceIdentifier) }
        terminalControlKeyStore.save(terminalControlKeys)
    }

    @discardableResult
    func saveProfile(_ profile: HostProfile, credentials: HostProfileCredentials) -> Bool {
        guard case .success = profileCredentialPersistence.save(credentials, for: profile.id) else {
            credentialStorageError = "Unable to save credentials for \(profile.displayName)."
            return false
        }
        if let index = hostProfiles.firstIndex(where: { $0.id == profile.id }) { hostProfiles[index] = profile }
        else { hostProfiles.append(profile) }
        profileStore.save(hostProfiles)
        if selectedNVDAProfileID == nil { selectedNVDAProfileID = profile.id }
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
        if selectedNVDAProfileID == profile.id { selectedNVDAProfileID = hostProfiles.first?.id }
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
    func nvdaBridgeCommand(for profile: HostProfile) -> String {
        var command = profile.nvdaBridgeCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.isEmpty { command = "farrelay" }
        var argv = [command, "--ipc", "--host", relayHost, "--port", String(relayPort), "--channel", channel]
        if !fingerprint.isEmpty { argv += ["--fingerprint", fingerprint] }
        if insecure { argv.append("--insecure") }
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
            farRelayHostCommand: "farrelay-host",
            nvdaBridgeCommand: defaults.string(forKey: Keys.legacyRemoteCommand) ?? "farrelay"
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

    private func saveSelectedNVDAProfileID() {
        if let selectedNVDAProfileID { defaults.set(selectedNVDAProfileID.uuidString, forKey: Keys.selectedNVDAProfileID) }
        else { defaults.removeObject(forKey: Keys.selectedNVDAProfileID) }
    }

    private enum Keys {
        static let hostProfiles = "farrelay.hostProfiles"
        static let selectedNVDAProfileID = "farrelay.selectedNVDAProfileID"
        static let relayHost = "farrelay.relayHost"
        static let relayPort = "farrelay.relayPort"
        static let channel = "farrelay.channel"
        static let fingerprint = "farrelay.fingerprint"
        static let insecure = "farrelay.insecure"
        static let nvdaModifier = "farrelay.nvdaModifier"
        static let optionMapping = "farrelay.optionMapping"
        static let commandMapping = "farrelay.commandMapping"
        static let speechRate = "farrelay.speechRate"
        static let voiceIdentifier = "farrelay.voiceIdentifier"
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
