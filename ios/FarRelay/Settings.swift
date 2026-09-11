import Foundation
import Observation

/// Which physical key on the BT keyboard acts as the NVDA modifier on the wire.
///
/// CapsLock is the closest analog to NVDA's default Insert and is reachable on
/// every Bluetooth keyboard. iOS does deliver press/release `UIPress` events
/// for it as long as the app has focus and VoiceOver isn't intercepting them
/// — when it does intercept, switch to ``voKeys`` (Ctrl+Option, the standard
/// VoiceOver convention) which is also commonly used as a screen-reader
/// modifier and is harder for the OS to swallow.
enum NvdaModifier: String, CaseIterable, Identifiable, Sendable {
    case capsLock
    case voKeys

    var id: String { rawValue }
    var label: String {
        switch self {
        case .capsLock: return "CapsLock"
        case .voKeys: return "VO keys (Ctrl+Option)"
        }
    }
}

/// What a Mac-style modifier key sends to the slave.
///
/// Mac BT keyboards report Option as `keyboardLeftAlt`/`keyboardRightAlt`
/// and Command as `keyboardLeftGUI`/`keyboardRightGUI`. Out of the box we
/// map Option → Alt and Command → Alt (the user's preference), but both
/// are configurable so the layout matches whatever's reachable on the
/// bridge keyboard.
enum ModifierMapping: String, CaseIterable, Identifiable, Sendable {
    case alt
    case win
    case ctrl
    case none

    var id: String { rawValue }
    var label: String {
        switch self {
        case .alt: return "Alt"
        case .win: return "Windows / GUI"
        case .ctrl: return "Ctrl"
        case .none: return "Ignore"
        }
    }
}

/// SSH auth strategy. Many bridge hosts disable password auth entirely, so
/// key auth needs to be a first-class option.
enum SSHAuthMode: String, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey

    var id: String { rawValue }
    var label: String {
        switch self {
        case .password: return "Password"
        case .privateKey: return "Private key"
        }
    }
}

@Observable
@MainActor
final class AppSettings {
    // SSH bridge
    var sshHost: String
    var sshPort: Int
    var sshUser: String
    var sshAuthMode: SSHAuthMode
    var sshPassword: String
    var sshPrivateKeyPEM: String
    var sshPrivateKeyPassphrase: String
    var remoteFarRelayCommand: String
    private(set) var credentialStorageError: String?

    // Relay (forwarded as farrelay --ipc args on the bridge)
    var relayHost: String
    var relayPort: Int
    var channel: String
    var fingerprint: String
    var insecure: Bool

    // Local input
    var nvdaModifier: NvdaModifier
    var optionMapping: ModifierMapping
    var commandMapping: ModifierMapping

    // Speech
    var speechRate: Float
    var voiceIdentifier: String?

    private let credentialPersistence: SSHCredentialPersistence

    init(
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStore = KeychainCredentialStore()
    ) {
        let d = defaults
        credentialPersistence = SSHCredentialPersistence(defaults: d, store: credentialStore)
        let migrationDiagnostics = credentialPersistence.migrateLegacyValues()
        sshHost = d.string(forKey: Keys.sshHost) ?? ""
        sshPort = d.object(forKey: Keys.sshPort) as? Int ?? 22
        sshUser = d.string(forKey: Keys.sshUser) ?? ""
        sshAuthMode = SSHAuthMode(rawValue: d.string(forKey: Keys.sshAuthMode) ?? "") ?? .password
        sshPassword = (try? credentialStore.string(for: SSHCredential.password.account)) ?? ""
        sshPrivateKeyPEM = (try? credentialStore.string(for: SSHCredential.privateKey.account)) ?? ""
        sshPrivateKeyPassphrase = (try? credentialStore.string(for: SSHCredential.privateKeyPassphrase.account)) ?? ""
        remoteFarRelayCommand = d.string(forKey: Keys.remoteFarRelayCommand) ?? "farrelay"
        relayHost = d.string(forKey: Keys.relayHost) ?? "nvdaremote.com"
        relayPort = d.object(forKey: Keys.relayPort) as? Int ?? 6837
        channel = d.string(forKey: Keys.channel) ?? ""
        fingerprint = d.string(forKey: Keys.fingerprint) ?? ""
        insecure = d.bool(forKey: Keys.insecure)
        nvdaModifier = NvdaModifier(rawValue: d.string(forKey: Keys.nvdaModifier) ?? "") ?? .capsLock
        optionMapping = ModifierMapping(rawValue: d.string(forKey: Keys.optionMapping) ?? "") ?? .win
        commandMapping = ModifierMapping(rawValue: d.string(forKey: Keys.commandMapping) ?? "") ?? .alt
        let storedRate = d.object(forKey: Keys.speechRate) as? Double
        speechRate = Float(storedRate ?? 0.55)
        voiceIdentifier = d.string(forKey: Keys.voiceIdentifier)
        credentialStorageError = migrationDiagnostics.first
    }

    func save() {
        let d = UserDefaults.standard
        d.set(sshHost, forKey: Keys.sshHost)
        d.set(sshPort, forKey: Keys.sshPort)
        d.set(sshUser, forKey: Keys.sshUser)
        d.set(sshAuthMode.rawValue, forKey: Keys.sshAuthMode)
        let secretWrites: [(String, SSHCredential)] = [
            (sshPassword, .password),
            (sshPrivateKeyPEM, .privateKey),
            (sshPrivateKeyPassphrase, .privateKeyPassphrase),
        ]
        credentialStorageError = nil
        for (value, credential) in secretWrites {
            if case .failure(let error) = credentialPersistence.save(value, for: credential) {
                credentialStorageError = "Unable to save \(credential.account): \(error.localizedDescription)"
                break
            }
        }
        d.set(remoteFarRelayCommand, forKey: Keys.remoteFarRelayCommand)
        d.set(relayHost, forKey: Keys.relayHost)
        d.set(relayPort, forKey: Keys.relayPort)
        d.set(channel, forKey: Keys.channel)
        d.set(fingerprint, forKey: Keys.fingerprint)
        d.set(insecure, forKey: Keys.insecure)
        d.set(nvdaModifier.rawValue, forKey: Keys.nvdaModifier)
        d.set(optionMapping.rawValue, forKey: Keys.optionMapping)
        d.set(commandMapping.rawValue, forKey: Keys.commandMapping)
        d.set(Double(speechRate), forKey: Keys.speechRate)
        if let id = voiceIdentifier {
            d.set(id, forKey: Keys.voiceIdentifier)
        } else {
            d.removeObject(forKey: Keys.voiceIdentifier)
        }
    }

    /// Build the remote farrelay --ipc invocation for the SSH exec channel.
    /// Whitespace / shell-meta in `channel` is shell-quoted so it can't break
    /// out of the remote command.
    func remoteCommand() -> String {
        var argv: [String] = []
        let cmd = remoteFarRelayCommand.trimmingCharacters(in: .whitespaces)
        argv.append(cmd.isEmpty ? "farrelay" : cmd)
        argv.append("--ipc")
        argv.append("--host"); argv.append(relayHost)
        argv.append("--port"); argv.append(String(relayPort))
        argv.append("--channel"); argv.append(channel)
        if !fingerprint.isEmpty {
            argv.append("--fingerprint"); argv.append(fingerprint)
        }
        if insecure {
            argv.append("--insecure")
        }
        return argv.map(shellQuote).joined(separator: " ")
    }

    /// Reuses the saved SSH endpoint and authentication for app features that
    /// open a normal SSH session rather than the NVDA IPC exec channel.
    func sshSessionConfiguration() -> SSHSessionConfiguration {
        let authentication: SSHAuthenticationConfiguration
        switch sshAuthMode {
        case .password:
            authentication = .password(sshPassword)
        case .privateKey:
            authentication = .privateKey(
                pem: sshPrivateKeyPEM,
                passphrase: sshPrivateKeyPassphrase
            )
        }
        return SSHSessionConfiguration(
            host: sshHost,
            port: sshPort,
            username: sshUser,
            authentication: authentication
        )
    }

    private enum Keys {
        static let sshHost = "farrelay.sshHost"
        static let sshPort = "farrelay.sshPort"
        static let sshUser = "farrelay.sshUser"
        static let sshAuthMode = "farrelay.sshAuthMode"
        static let remoteFarRelayCommand = "farrelay.remoteCommand"
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
    }
}

/// POSIX single-quote shell quoting. Equivalent to Python's `shlex.quote`.
private func shellQuote(_ s: String) -> String {
    if s.isEmpty { return "''" }
    let safe = s.allSatisfy { ch in
        ch.isLetter || ch.isNumber || "@%+=:,./-_".contains(ch)
    }
    if safe { return s }
    return "'" + s.replacing("'", with: "'\\''") + "'"
}
