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
    private let defaultsKey = "farrelay.sshHostIdentities"

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

    func verification(for presentedFingerprint: String) throws -> SSHHostIdentityVerification {
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
                return .alreadyTrusted
            } else {
                return .trustOnSuccessfulConnection(presentedFingerprint)
            }
        } catch let error as SSHHostIdentityError {
            throw error
        } catch {
            throw SSHHostIdentityError.identityStoreFailure(error.localizedDescription)
        }
    }

    func commit(_ verification: SSHHostIdentityVerification) throws {
        guard case let .trustOnSuccessfulConnection(fingerprint) = verification else { return }
        do {
            try store.store(fingerprint: fingerprint, for: endpoint)
        } catch {
            throw SSHHostIdentityError.identityStoreFailure(error.localizedDescription)
        }
    }

    func verify(presentedFingerprint: String) throws {
        let verification = try verification(for: presentedFingerprint)
        try commit(verification)
    }
}

enum SSHHostIdentityVerification: Sendable, Equatable {
    case alreadyTrusted
    case trustOnSuccessfulConnection(String)
}

/// A synchronous gate used by NIO's host-key callback and the actor owning a
/// connection attempt. Citadel does not expose a client before connect returns,
/// so this gate prevents a stopped attempt from validating or persisting a
/// first-use host identity while it is still negotiating.
final class SSHConnectionAttemptGate: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }

    func performIfValid(_ operation: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard valid else { throw CancellationError() }
        try operation()
    }

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
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
    private let gate: SSHConnectionAttemptGate
    private let lock = NSLock()
    private var pendingVerification: SSHHostIdentityVerification?

    init(
        endpoint: SSHHostEndpoint,
        store: SSHHostIdentityStore,
        gate: SSHConnectionAttemptGate = SSHConnectionAttemptGate()
    ) {
        verifier = SSHHostIdentityVerifier(endpoint: endpoint, store: store)
        self.gate = gate
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            try gate.performIfValid {
                let verification = try verifier.verification(
                    for: SSHHostKeyFingerprint.fingerprint(for: hostKey)
                )
                lock.lock()
                pendingVerification = verification
                lock.unlock()
            }
            validationCompletePromise.succeed(())
        } catch {
            validationCompletePromise.fail(error)
        }
    }

    /// First-use identity storage is delayed until Citadel has completed the
    /// connection and the owning attempt remains valid. Existing identities
    /// are never removed or rewritten by cancellation.
    func commitValidatedIdentity() throws {
        lock.lock()
        let verification = pendingVerification
        lock.unlock()
        guard let verification else { return }
        try gate.performIfValid {
            try verifier.commit(verification)
        }
    }
}
