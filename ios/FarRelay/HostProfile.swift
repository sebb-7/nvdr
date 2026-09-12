import Foundation

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
    /// Stable metadata reference for this profile's device-local Keychain
    /// namespace. It identifies a credential location, never credential data.
    var credentialReference: String
    /// Structured host protocol command. It is not the NVDA relay command.
    var farRelayHostCommand: String
    /// Legacy NVDA bridge command, invoked with `--ipc` by AppSettings.
    var nvdaBridgeCommand: String

    init(
        id: UUID = UUID(),
        displayName: String = "New Computer",
        address: String = "",
        port: Int = 22,
        username: String = "",
        authenticationMode: SSHAuthMode = .password,
        credentialReference: String? = nil,
        farRelayHostCommand: String = "farrelay-host",
        nvdaBridgeCommand: String = "farrelay"
    ) {
        self.id = id
        self.displayName = displayName
        self.address = address
        self.port = port
        self.username = username
        self.authenticationMode = authenticationMode
        self.credentialReference = credentialReference ?? "keychain.profile.\(id.uuidString.lowercased())"
        self.farRelayHostCommand = farRelayHostCommand
        self.nvdaBridgeCommand = nvdaBridgeCommand
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
}

enum HostProfileStoreValue: Equatable {
    case uninitialized
    case profiles([HostProfile])
    case malformed
}

struct HostProfileStore {
    let defaults: UserDefaults
    let key: String

    func load() -> HostProfileStoreValue {
        guard let data = defaults.data(forKey: key) else { return .uninitialized }
        do {
            return .profiles(try JSONDecoder().decode([HostProfile].self, from: data))
        } catch {
            return .malformed
        }
    }

    func save(_ profiles: [HostProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: key)
    }
}

enum AppShellTab: String, CaseIterable, Identifiable, Sendable {
    case home
    case nvda
    case terminals
    case agents
    case assistant

    var id: String { rawValue }
}
