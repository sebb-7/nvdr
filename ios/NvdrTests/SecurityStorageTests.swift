import XCTest
@testable import Nvdr

final class SecurityStorageTests: XCTestCase {
    func testCredentialStoreLoadsMissingValue() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.string(for: SSHCredential.password.account))
    }

    func testCredentialStoreStoresReplacesAndDeletesValue() throws {
        let store = InMemoryCredentialStore()
        try store.store("first", for: SSHCredential.password.account)
        XCTAssertEqual(try store.string(for: SSHCredential.password.account), "first")

        try store.store("second", for: SSHCredential.password.account)
        XCTAssertEqual(try store.string(for: SSHCredential.password.account), "second")

        try store.removeValue(for: SSHCredential.password.account)
        XCTAssertNil(try store.string(for: SSHCredential.password.account))
    }

    func testLegacyMigrationMovesAndRemovesSecretsAfterVerifiedWrite() throws {
        let defaults = try makeDefaults()
        defaults.set("password", forKey: SSHCredential.password.legacyDefaultsKey)
        defaults.set("private key", forKey: SSHCredential.privateKey.legacyDefaultsKey)
        defaults.set("passphrase", forKey: SSHCredential.privateKeyPassphrase.legacyDefaultsKey)
        let store = InMemoryCredentialStore()

        let diagnostics = SSHCredentialPersistence(defaults: defaults, store: store).migrateLegacyValues()

        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertEqual(try store.string(for: SSHCredential.password.account), "password")
        XCTAssertEqual(try store.string(for: SSHCredential.privateKey.account), "private key")
        XCTAssertEqual(try store.string(for: SSHCredential.privateKeyPassphrase.account), "passphrase")
        XCTAssertNil(defaults.object(forKey: SSHCredential.password.legacyDefaultsKey))
        XCTAssertNil(defaults.object(forKey: SSHCredential.privateKey.legacyDefaultsKey))
        XCTAssertNil(defaults.object(forKey: SSHCredential.privateKeyPassphrase.legacyDefaultsKey))
    }

    func testLegacyMigrationRetainsValueWhenSecureWriteFails() throws {
        let defaults = try makeDefaults()
        defaults.set("password", forKey: SSHCredential.password.legacyDefaultsKey)
        let store = InMemoryCredentialStore(failWrites: true)

        let diagnostics = SSHCredentialPersistence(defaults: defaults, store: store).migrateLegacyValues()

        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(defaults.string(forKey: SSHCredential.password.legacyDefaultsKey), "password")
        XCTAssertNil(try store.string(for: SSHCredential.password.account))
    }

    func testFirstUseStoresPresentedFingerprint() throws {
        let store = InMemoryHostIdentityStore()
        let endpoint = SSHHostEndpoint(host: "Example.COM", port: 22)

        try SSHHostIdentityVerifier(endpoint: endpoint, store: store).verify(presentedFingerprint: "SHA256:first")

        XCTAssertEqual(try store.fingerprint(for: endpoint), "SHA256:first")
    }

    func testStoppedFirstUseAttemptCannotPersistHostIdentity() throws {
        let store = InMemoryHostIdentityStore()
        let endpoint = SSHHostEndpoint(host: "example.com", port: 22)
        let verifier = SSHHostIdentityVerifier(endpoint: endpoint, store: store)
        let verification = try verifier.verification(for: "SHA256:first")
        let gate = SSHConnectionAttemptGate()

        gate.invalidate()

        XCTAssertThrowsError(
            try gate.performIfValid {
                try verifier.commit(verification)
            }
        )
        XCTAssertNil(try store.fingerprint(for: endpoint))
    }

    func testMatchingHostIdentitySucceeds() throws {
        let store = InMemoryHostIdentityStore()
        let endpoint = SSHHostEndpoint(host: "example.com", port: 22)
        try store.store(fingerprint: "SHA256:same", for: endpoint)

        XCTAssertNoThrow(
            try SSHHostIdentityVerifier(endpoint: endpoint, store: store).verify(presentedFingerprint: "SHA256:same")
        )
    }

    func testChangedHostIdentityFailsClosedWithDetails() throws {
        let store = InMemoryHostIdentityStore()
        let endpoint = SSHHostEndpoint(host: "example.com", port: 22)
        try store.store(fingerprint: "SHA256:expected", for: endpoint)

        XCTAssertThrowsError(
            try SSHHostIdentityVerifier(endpoint: endpoint, store: store).verify(presentedFingerprint: "SHA256:presented")
        ) { error in
            guard let identityError = error as? SSHHostIdentityError,
                  case .hostKeyChanged(let change) = identityError else {
                return XCTFail("Expected a host-key change error, got \(error)")
            }
            XCTAssertEqual(change.host, "example.com")
            XCTAssertEqual(change.port, 22)
            XCTAssertEqual(change.expectedFingerprint, "SHA256:expected")
            XCTAssertEqual(change.presentedFingerprint, "SHA256:presented")
        }
    }

    func testHostIdentityPortIsPartOfEndpointKey() throws {
        let store = InMemoryHostIdentityStore()
        let standardPort = SSHHostEndpoint(host: "example.com", port: 22)
        let alternatePort = SSHHostEndpoint(host: "example.com", port: 2222)
        try store.store(fingerprint: "SHA256:one", for: standardPort)
        try store.store(fingerprint: "SHA256:two", for: alternatePort)

        XCTAssertNotEqual(standardPort.storageKey, alternatePort.storageKey)
        XCTAssertEqual(try store.fingerprint(for: standardPort), "SHA256:one")
        XCTAssertEqual(try store.fingerprint(for: alternatePort), "SHA256:two")
    }

    func testFingerprintIsStableAndComparedExactly() {
        let first = SSHHostKeyFingerprint.fingerprint(forWireData: Data("wire-key".utf8))
        let second = SSHHostKeyFingerprint.fingerprint(forWireData: Data("wire-key".utf8))
        let different = SSHHostKeyFingerprint.fingerprint(forWireData: Data("WIRE-key".utf8))

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, different)
        XCTAssertTrue(first.hasPrefix("SHA256:"))
    }

    func testInsecureHostKeyPolicyIsExplicitOptIn() {
        XCTAssertEqual(SSHHostKeyPolicy.trustOnFirstUse, .trustOnFirstUse)
        XCTAssertNotEqual(SSHHostKeyPolicy.trustOnFirstUse, .insecureAcceptAnything)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "NvdrTests.SecurityStorageTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("Unable to create isolated UserDefaults suite.")
        }
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}

private final class InMemoryCredentialStore: CredentialStore {
    private var values: [String: String] = [:]
    private let failWrites: Bool

    init(failWrites: Bool = false) {
        self.failWrites = failWrites
    }

    func string(for account: String) throws -> String? {
        values[account]
    }

    func store(_ value: String, for account: String) throws {
        if failWrites { throw InMemoryStoreError.writeFailed }
        values[account] = value
    }

    func removeValue(for account: String) throws {
        values.removeValue(forKey: account)
    }
}

private final class InMemoryHostIdentityStore: SSHHostIdentityStore {
    private var identities: [SSHHostEndpoint: String] = [:]

    func fingerprint(for endpoint: SSHHostEndpoint) throws -> String? {
        identities[endpoint]
    }

    func store(fingerprint: String, for endpoint: SSHHostEndpoint) throws {
        identities[endpoint] = fingerprint
    }
}

private enum InMemoryStoreError: LocalizedError {
    case writeFailed

    var errorDescription: String? { "In-memory write failed." }
}
