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

    init(service: String = "com.oriolgomez.nvdr.ssh-credentials") {
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
        case .password: return "nvdr.sshPassword"
        case .privateKey: return "nvdr.sshPrivateKeyPEM"
        case .privateKeyPassphrase: return "nvdr.sshPrivateKeyPassphrase"
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
