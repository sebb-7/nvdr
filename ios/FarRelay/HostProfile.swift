import Foundation

enum HostPlatform: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case windows
    case macOS
    case linux
    case other

    var id: String { rawValue }
    var label: String {
        switch self {
        case .windows: "Windows"
        case .macOS: "macOS"
        case .linux: "Linux"
        case .other: "Other"
        }
    }
}

/// Optional, explicit NVDA Remote support for a Windows computer. Relay values
/// are connection metadata, while SSH credentials remain in the Keychain.
struct NVDARemoteCapability: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var relayHost: String
    var relayPort: Int
    var channel: String
    var fingerprint: String
    var insecure: Bool

    init(
        isEnabled: Bool = false,
        relayHost: String = "nvdaremote.com",
        relayPort: Int = 6837,
        channel: String = "",
        fingerprint: String = "",
        insecure: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.relayHost = relayHost
        self.relayPort = relayPort
        self.channel = channel
        self.fingerprint = fingerprint
        self.insecure = insecure
    }

    /// Relay host names and channel secrets are opaque protocol values, but
    /// copy/paste commonly adds a trailing newline. Normalize only surrounding
    /// whitespace before persistence and command construction; the channel is
    /// never logged or included in user-facing diagnostics.
    func normalized() -> Self {
        var copy = self
        copy.relayHost = relayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.channel = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.fingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

/// Mac Remote uses the bundled target-app proxy over the existing SSH trust
/// path. It remains separate from NVDA Remote's relay channel.
struct MacRemoteCapability: Codable, Equatable, Sendable {
    var isEnabled: Bool

    init(isEnabled: Bool = false) { self.isEnabled = isEnabled }
}

/// A saved SSH computer. This is intentionally transport-neutral metadata:
/// passwords and private keys stay in the device Keychain, never in Codable
/// profile persistence.
struct HostProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var displayName: String
    /// An ordinary SSH hostname or address. It may be a Tailscale address, but
    /// the app makes no VPN or network assumptions about it.
    var address: String
    var port: Int
    var username: String
    var authenticationMode: SSHAuthMode
    var platform: HostPlatform
    /// Stable metadata reference for this profile's device-local Keychain
    /// namespace. It identifies a credential location, never credential data.
    var credentialReference: String
    /// Structured host protocol command. It is not the NVDA relay command.
    var farRelayHostCommand: String
    /// Legacy NVDA bridge command, invoked with `--ipc` by AppSettings.
    var nvdaBridgeCommand: String
    var nvdaRemote: NVDARemoteCapability?
    var macRemote: MacRemoteCapability?

    init(
        id: UUID = UUID(),
        displayName: String = "New Computer",
        address: String = "",
        port: Int = 22,
        username: String = "",
        authenticationMode: SSHAuthMode = .password,
        platform: HostPlatform = .other,
        credentialReference: String? = nil,
        farRelayHostCommand: String = "farrelay-host",
        nvdaBridgeCommand: String = "farrelay",
        nvdaRemote: NVDARemoteCapability? = nil,
        macRemote: MacRemoteCapability? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.address = address
        self.port = port
        self.username = username
        self.authenticationMode = authenticationMode
        self.platform = platform
        self.credentialReference = credentialReference ?? "keychain.profile.\(id.uuidString.lowercased())"
        self.farRelayHostCommand = farRelayHostCommand
        self.nvdaBridgeCommand = nvdaBridgeCommand
        self.nvdaRemote = nvdaRemote
        self.macRemote = macRemote
    }

    func sshSessionConfiguration(credentials: HostProfileCredentials) -> SSHSessionConfiguration {
        let authentication: SSHAuthenticationConfiguration
        switch authenticationMode {
        case .password:
            authentication = .password(credentials.password)
        case .privateKey:
            authentication = .privateKey(
                pem: credentials.privateKeyPEM,
                passphrase: credentials.privateKeyPassphrase
            )
        }
        return SSHSessionConfiguration(
            host: address,
            port: port,
            username: username,
            authentication: authentication
        )
    }

    var isConnectionReady: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (1...65535).contains(port)
    }

    /// NVDA Remote is a Windows host capability. A leftover record on another
    /// platform must not activate the bridge.
    var isNVDARemoteEnabled: Bool {
        platform == .windows && nvdaRemote?.isEnabled == true
    }

    var isMacRemoteEnabled: Bool { platform == .macOS && macRemote?.isEnabled == true }

    /// The shipped direct-distribution app embeds this proxy at the stable
    /// Applications location. It fails closed if FarRelay.app is not running.
    var macRemoteHostCommand: String {
        "'/Applications/FarRelay.app/Contents/Helpers/farrelay-host' --proxy"
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, address, port, username, authenticationMode
        case platform, credentialReference, farRelayHostCommand, nvdaBridgeCommand, nvdaRemote, macRemote
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        address = try values.decode(String.self, forKey: .address)
        port = try values.decode(Int.self, forKey: .port)
        username = try values.decode(String.self, forKey: .username)
        authenticationMode = try values.decode(SSHAuthMode.self, forKey: .authenticationMode)
        platform = try values.decodeIfPresent(HostPlatform.self, forKey: .platform) ?? .other
        credentialReference = try values.decodeIfPresent(String.self, forKey: .credentialReference)
            ?? "keychain.profile.\(id.uuidString.lowercased())"
        farRelayHostCommand = try values.decodeIfPresent(String.self, forKey: .farRelayHostCommand) ?? "farrelay-host"
        nvdaBridgeCommand = try values.decodeIfPresent(String.self, forKey: .nvdaBridgeCommand) ?? "farrelay"
        nvdaRemote = try values.decodeIfPresent(NVDARemoteCapability.self, forKey: .nvdaRemote)
        macRemote = try values.decodeIfPresent(MacRemoteCapability.self, forKey: .macRemote)
    }
}

enum HostProfileStoreValue: Equatable {
    case uninitialized
    case profiles([HostProfile])
    /// The pre-Phase 3 `[HostProfile]` payload. Settings migrates this only
    /// after retaining the exact source bytes for recovery.
    case legacyProfiles([HostProfile])
    case malformed
    case unsupportedSchema(Int)
}

struct HostProfileStore {
    static let currentSchemaVersion = 1
    let defaults: UserDefaults
    let key: String

    func load() -> HostProfileStoreValue {
        guard let data = defaults.data(forKey: key) else { return .uninitialized }
        if let envelope = try? JSONDecoder().decode(HostProfileStoreEnvelope.self, from: data) {
            guard envelope.schemaVersion == Self.currentSchemaVersion else {
                return .unsupportedSchema(envelope.schemaVersion)
            }
            return .profiles(envelope.profiles)
        }
        if let legacy = try? JSONDecoder().decode([HostProfile].self, from: data) {
            return .legacyProfiles(legacy)
        }
        return .malformed
    }

    /// UserDefaults replaces its value atomically. The Boolean permits callers
    /// to retain their in-memory model and surface recovery state if encoding
    /// ever fails instead of pretending a write succeeded.
    @discardableResult
    func save(_ profiles: [HostProfile]) -> Bool {
        guard let data = try? JSONEncoder().encode(
            HostProfileStoreEnvelope(schemaVersion: Self.currentSchemaVersion, profiles: profiles)
        ) else { return false }
        defaults.set(data, forKey: key)
        return defaults.data(forKey: key) == data
    }

    /// Preserve old bytes before replacing a successfully decoded legacy store.
    /// The backup is bounded to one source payload and never contains Keychain
    /// secrets because HostProfile persistence is metadata-only.
    @discardableResult
    func migrateLegacy(_ profiles: [HostProfile]) -> Bool {
        guard let original = defaults.data(forKey: key) else { return false }
        defaults.set(original, forKey: "\(key).migrationSource")
        guard save(profiles) else { return false }
        return true
    }
}

private struct HostProfileStoreEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let profiles: [HostProfile]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schemaVersion"
        case profiles
    }
}

enum AppShellTab: String, CaseIterable, Identifiable, Sendable {
    case home
    case remoteControl
    case terminals
    case agents
    case assistant

    var id: String { rawValue }
}
