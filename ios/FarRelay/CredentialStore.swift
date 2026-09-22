import Foundation
import Security

protocol CredentialStore: AnyObject {
    func string(for account: String) throws -> String?
    func store(_ value: String, for account: String) throws
    func removeValue(for account: String) throws
}

enum CredentialStoreError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidStoredValue

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed (status \(status))."
        case .invalidStoredValue:
            return "Keychain returned an invalid credential value."
        }
    }
}

/// Stores application SSH secrets in the device-local Keychain. The
/// `WhenUnlockedThisDeviceOnly` policy keeps credentials off backups and
/// prevents them from migrating to a different device.
final class KeychainCredentialStore: CredentialStore {
    private let service: String

    init(service: String = "com.sebb7.farrelay.ssh-credentials") {
        self.service = service
    }

    func string(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidStoredValue
        }
        return value
    }

    func store(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialStoreError.unexpectedStatus(addStatus) }
    }

    func removeValue(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

enum SSHCredential: CaseIterable {
    case password
    case privateKey
    case privateKeyPassphrase

    var account: String {
        switch self {
        case .password: return "ssh.password"
        case .privateKey: return "ssh.privateKey"
        case .privateKeyPassphrase: return "ssh.privateKeyPassphrase"
        }
    }

    var legacyDefaultsKey: String {
        switch self {
        case .password: return "farrelay.sshPassword"
        case .privateKey: return "farrelay.sshPrivateKeyPEM"
        case .privateKeyPassphrase: return "farrelay.sshPrivateKeyPassphrase"
        }
    }
}

struct SSHCredentialPersistence {
    let defaults: UserDefaults
    let store: CredentialStore

    func migrateLegacyValues() -> [String] {
        var diagnostics: [String] = []
        for credential in SSHCredential.allCases {
            guard let legacyValue = defaults.string(forKey: credential.legacyDefaultsKey) else { continue }
            do {
                if try store.string(for: credential.account) == nil {
                    try store.store(legacyValue, for: credential.account)
                    guard try store.string(for: credential.account) == legacyValue else {
                        throw CredentialStoreError.invalidStoredValue
                    }
                }
                defaults.removeObject(forKey: credential.legacyDefaultsKey)
            } catch {
                diagnostics.append("Unable to migrate \(credential.account): \(error.localizedDescription)")
            }
        }
        return diagnostics
    }

    func load(_ credential: SSHCredential) -> Result<String, Error> {
        Result { try store.string(for: credential.account) ?? "" }
    }

    func save(_ value: String, for credential: SSHCredential) -> Result<Void, Error> {
        Result {
            if value.isEmpty {
                try store.removeValue(for: credential.account)
            } else {
                try store.store(value, for: credential.account)
            }
        }
    }
}

/// Credentials owned by one saved computer. The profile UUID is part of every
/// Keychain account name so credentials can never be read through another
/// profile's settings or serialized with the profile metadata.
enum HostProfileCredential: CaseIterable {
    case password
    case privateKey
    case privateKeyPassphrase
    case remSoundPassword

    func account(for profileID: UUID) -> String {
        "ssh.profile.\(profileID.uuidString.lowercased()).\(suffix)"
    }

    private var suffix: String {
        switch self {
        case .password: "password"
        case .privateKey: "privateKey"
        case .privateKeyPassphrase: "privateKeyPassphrase"
        case .remSoundPassword: "remsoundPassword"
        }
    }

    fileprivate var legacyCredential: SSHCredential? {
        switch self {
        case .password: .password
        case .privateKey: .privateKey
        case .privateKeyPassphrase: .privateKeyPassphrase
        case .remSoundPassword: nil
        }
    }
}

struct HostProfileCredentials: Equatable, Sendable {
    var password: String = ""
    var privateKeyPEM: String = ""
    var privateKeyPassphrase: String = ""
    /// An audio-only secret. It stays in Keychain and is never serialized in
    /// HostProfile, logs, clipboard diagnostics, or the RemSound format packet.
    var remSoundPassword: String = ""
}

struct HostProfileCredentialPersistence {
    let store: CredentialStore

    func load(for profileID: UUID) -> Result<HostProfileCredentials, Error> {
        Result {
            HostProfileCredentials(
                password: try store.string(for: HostProfileCredential.password.account(for: profileID)) ?? "",
                privateKeyPEM: try store.string(for: HostProfileCredential.privateKey.account(for: profileID)) ?? "",
                privateKeyPassphrase: try store.string(for: HostProfileCredential.privateKeyPassphrase.account(for: profileID)) ?? "",
                remSoundPassword: try store.string(for: HostProfileCredential.remSoundPassword.account(for: profileID)) ?? ""
            )
        }
    }

    func save(_ credentials: HostProfileCredentials, for profileID: UUID) -> Result<Void, Error> {
        Result {
            try save(credentials.password, credential: .password, profileID: profileID)
            try save(credentials.privateKeyPEM, credential: .privateKey, profileID: profileID)
            try save(credentials.privateKeyPassphrase, credential: .privateKeyPassphrase, profileID: profileID)
            try save(credentials.remSoundPassword, credential: .remSoundPassword, profileID: profileID)
        }
    }

    func deleteCredentials(for profileID: UUID) -> Result<Void, Error> {
        Result {
            for credential in HostProfileCredential.allCases {
                try store.removeValue(for: credential.account(for: profileID))
            }
        }
    }

    /// Copies the former single-profile secrets only after every destination
    /// value has been written and read back. The old accounts are then removed
    /// so they cannot become a second writable profile source.
    func migrateLegacyCredentials(to profileID: UUID, defaults: UserDefaults) -> Result<Void, Error> {
        Result {
            var copied: [(HostProfileCredential, LegacySource)] = []
            for credential in HostProfileCredential.allCases {
                guard let legacyCredential = credential.legacyCredential else { continue }
                let source: LegacySource
                if let value = try store.string(for: legacyCredential.account) {
                    source = .keychain(value)
                } else if let value = defaults.string(forKey: legacyCredential.legacyDefaultsKey) {
                    source = .defaults(value)
                } else {
                    continue
                }
                let value = source.value
                let destination = credential.account(for: profileID)
                if try store.string(for: destination) == nil {
                    try store.store(value, for: destination)
                }
                guard try store.string(for: destination) == value else {
                    throw CredentialStoreError.invalidStoredValue
                }
                copied.append((credential, source))
            }
            for (credential, source) in copied {
                switch source {
                case .keychain:
                    if let legacyCredential = credential.legacyCredential {
                        try store.removeValue(for: legacyCredential.account)
                    }
                case .defaults:
                    if let legacyCredential = credential.legacyCredential {
                        defaults.removeObject(forKey: legacyCredential.legacyDefaultsKey)
                    }
                }
            }
        }
    }

    private func save(_ value: String, credential: HostProfileCredential, profileID: UUID) throws {
        let account = credential.account(for: profileID)
        if value.isEmpty {
            try store.removeValue(for: account)
        } else {
            try store.store(value, for: account)
        }
    }

    private enum LegacySource {
        case keychain(String)
        case defaults(String)

        var value: String {
            switch self {
            case .keychain(let value), .defaults(let value): value
            }
        }
    }
}
