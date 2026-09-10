import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH

struct SSHHostEndpoint: Hashable, Sendable {
    let host: String
    let port: Int

    init(host: String, port: Int) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port
    }

    /// Length-prefixing keeps host/port identity keys unambiguous, including
    /// IPv6 literals: `<utf8-byte-count>|<normalized-host>|<port>`.
    var storageKey: String { "\(host.lengthOfBytes(using: .utf8))|\(host)|\(port)" }
}

protocol SSHHostIdentityStore: AnyObject {
    func fingerprint(for endpoint: SSHHostEndpoint) throws -> String?
    func store(fingerprint: String, for endpoint: SSHHostEndpoint) throws
}

final class UserDefaultsSSHHostIdentityStore: SSHHostIdentityStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let defaultsKey = "nvdr.sshHostIdentities"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func fingerprint(for endpoint: SSHHostEndpoint) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return (defaults.dictionary(forKey: defaultsKey) ?? [:])[endpoint.storageKey] as? String
    }

    func store(fingerprint: String, for endpoint: SSHHostEndpoint) throws {
        lock.lock()
        defer { lock.unlock() }
        var identities = defaults.dictionary(forKey: defaultsKey) ?? [:]
        identities[endpoint.storageKey] = fingerprint
        defaults.set(identities, forKey: defaultsKey)
    }
}

enum SSHHostKeyPolicy: Sendable, Equatable {
    case trustOnFirstUse
    case insecureAcceptAnything
}

struct SSHHostKeyChange: Error, Equatable, Sendable {
    let host: String
    let port: Int
    let expectedFingerprint: String
    let presentedFingerprint: String
}

enum SSHHostIdentityError: LocalizedError, Equatable {
    case hostKeyChanged(SSHHostKeyChange)
    case unsupportedHostKey
    case identityStoreFailure(String)

    var errorDescription: String? {
        switch self {
        case .hostKeyChanged(let change):
            return "SSH host identity changed for \(change.host):\(change.port). Expected \(change.expectedFingerprint), received \(change.presentedFingerprint)."
        case .unsupportedHostKey:
            return "The SSH server presented an unsupported host key."
        case .identityStoreFailure:
            return "SSH host identity could not be stored or verified."
        }
    }
}

struct SSHHostIdentityVerifier {
    let endpoint: SSHHostEndpoint
    let store: SSHHostIdentityStore

    func verify(presentedFingerprint: String) throws {
        do {
            if let expected = try store.fingerprint(for: endpoint) {
                guard expected == presentedFingerprint else {
                    throw SSHHostIdentityError.hostKeyChanged(
                        SSHHostKeyChange(
                            host: endpoint.host,
                            port: endpoint.port,
                            expectedFingerprint: expected,
                            presentedFingerprint: presentedFingerprint
                        )
                    )
                }
            } else {
                try store.store(fingerprint: presentedFingerprint, for: endpoint)
            }
        } catch let error as SSHHostIdentityError {
            throw error
        } catch {
            throw SSHHostIdentityError.identityStoreFailure(error.localizedDescription)
        }
    }
}

enum SSHHostKeyFingerprint {
    static func fingerprint(forWireData data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return "SHA256:\(Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "=")))"
    }

    static func fingerprint(for hostKey: NIOSSHPublicKey) throws -> String {
        let parts = String(openSSHPublicKey: hostKey).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let wireData = Data(base64Encoded: String(parts[1])) else {
            throw SSHHostIdentityError.unsupportedHostKey
        }
        return fingerprint(forWireData: wireData)
    }
}

final class SSHTOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let verifier: SSHHostIdentityVerifier

    init(endpoint: SSHHostEndpoint, store: SSHHostIdentityStore) {
        verifier = SSHHostIdentityVerifier(endpoint: endpoint, store: store)
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            try verifier.verify(presentedFingerprint: SSHHostKeyFingerprint.fingerprint(for: hostKey))
            validationCompletePromise.succeed(())
        } catch {
            validationCompletePromise.fail(error)
        }
    }
}
