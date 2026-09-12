import XCTest
@testable import FarRelay

@MainActor
final class HostProfileTests: XCTestCase {
    func testProfileDefaultsKeepStructuredHostAndNVDACommandsDistinct() throws {
        let profile = HostProfile()
        XCTAssertEqual(profile.farRelayHostCommand, "farrelay-host")
        XCTAssertEqual(profile.nvdaBridgeCommand, "farrelay")
        XCTAssertTrue(profile.credentialReference.hasPrefix("keychain.profile."))
        let credentials = HostProfileCredentials(
            password: "SECRET_PASSWORD_VALUE",
            privateKeyPEM: "SECRET_PRIVATE_KEY_VALUE",
            privateKeyPassphrase: "SECRET_PASSPHRASE_VALUE"
        )

        let encoded = try JSONEncoder().encode(profile)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"authenticationMode\":\"password\""))
        XCTAssertTrue(text.contains("\"credentialReference\""))
        XCTAssertFalse(text.contains(credentials.password))
        XCTAssertFalse(text.contains(credentials.privateKeyPEM))
        XCTAssertFalse(text.contains(credentials.privateKeyPassphrase))
    }

    func testProfileCredentialAccountsAreDistinctAndScoped() {
        let first = UUID()
        let second = UUID()
        XCTAssertNotEqual(
            HostProfileCredential.password.account(for: first),
            HostProfileCredential.password.account(for: second)
        )
        XCTAssertNotEqual(
            HostProfileCredential.password.account(for: first),
            HostProfileCredential.privateKey.account(for: first)
        )
    }

    func testProfileStoreRoundTripKeepsMetadataOnly() throws {
        let defaults = try makeDefaults()
        let profile = HostProfile(displayName: "Desk", address: "100.64.0.2", username: "reader")
        let store = HostProfileStore(defaults: defaults, key: "profiles")

        XCTAssertEqual(store.load(), .uninitialized)
        store.save([profile])
        XCTAssertEqual(store.load(), .profiles([profile]))
    }

    func testMigrationImportsLegacyComputerOnceAndScopesCredentials() throws {
        let defaults = try makeDefaults()
        defaults.set("100.64.0.7", forKey: "farrelay.sshHost")
        defaults.set(2222, forKey: "farrelay.sshPort")
        defaults.set("nvda", forKey: "farrelay.sshUser")
        defaults.set("privateKey", forKey: "farrelay.sshAuthMode")
        defaults.set("legacy-farrelay", forKey: "farrelay.remoteCommand")
        let credentials = TestCredentialStore()
        try credentials.store("key", for: SSHCredential.privateKey.account)
        try credentials.store("passphrase", for: SSHCredential.privateKeyPassphrase.account)

        let settings = AppSettings(defaults: defaults, credentialStore: credentials)
        let profile = try XCTUnwrap(settings.hostProfiles.only)
        XCTAssertEqual(profile.displayName, "Imported Computer")
        XCTAssertEqual(profile.address, "100.64.0.7")
        XCTAssertEqual(profile.port, 2222)
        XCTAssertEqual(profile.username, "nvda")
        XCTAssertEqual(profile.nvdaBridgeCommand, "legacy-farrelay")
        XCTAssertEqual(try credentials.string(for: HostProfileCredential.privateKey.account(for: profile.id)), "key")
        XCTAssertNil(try credentials.string(for: SSHCredential.privateKey.account))
        XCTAssertNil(defaults.object(forKey: "farrelay.sshHost"))

        let reloaded = AppSettings(defaults: defaults, credentialStore: credentials)
        XCTAssertEqual(reloaded.hostProfiles, [profile])
    }

    func testDeletingProfileRemovesOnlyItsCredentials() throws {
        let defaults = try makeDefaults()
        let credentials = TestCredentialStore()
        let settings = AppSettings(defaults: defaults, credentialStore: credentials)
        let first = HostProfile(displayName: "First", address: "first", username: "user")
        let second = HostProfile(displayName: "Second", address: "second", username: "user")
        XCTAssertTrue(settings.saveProfile(first, credentials: HostProfileCredentials(password: "one")))
        XCTAssertTrue(settings.saveProfile(second, credentials: HostProfileCredentials(password: "two")))

        XCTAssertTrue(settings.deleteProfile(first))
        XCTAssertNil(try credentials.string(for: HostProfileCredential.password.account(for: first.id)))
        XCTAssertEqual(try credentials.string(for: HostProfileCredential.password.account(for: second.id)), "two")
        XCTAssertEqual(settings.hostProfiles, [second])
    }

    func testMigrationFailureRetainsLegacyConfigurationAndSecret() throws {
        let defaults = try makeDefaults()
        defaults.set("legacy.example", forKey: "farrelay.sshHost")
        defaults.set("reader", forKey: "farrelay.sshUser")
        defaults.set("password", forKey: SSHCredential.password.legacyDefaultsKey)
        let credentials = TestCredentialStore(failWrites: true)

        let settings = AppSettings(defaults: defaults, credentialStore: credentials)

        XCTAssertTrue(settings.hostProfiles.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "farrelay.sshHost"), "legacy.example")
        XCTAssertEqual(defaults.string(forKey: SSHCredential.password.legacyDefaultsKey), "password")
        XCTAssertNotNil(settings.credentialStorageError)
    }

    func testSelectedProfileBuildsSSHConfigurationAndSeparateNVDACommand() throws {
        let defaults = try makeDefaults()
        let credentials = TestCredentialStore()
        let settings = AppSettings(defaults: defaults, credentialStore: credentials)
        settings.channel = "relay channel"
        let profile = HostProfile(
            displayName: "Tailscale is just SSH",
            address: "100.64.0.8",
            port: 2200,
            username: "reader",
            farRelayHostCommand: "farrelay-host",
            nvdaBridgeCommand: "farrelay"
        )
        XCTAssertTrue(settings.saveProfile(profile, credentials: HostProfileCredentials(password: "secret")))
        let configuration = try XCTUnwrap(settings.sshSessionConfiguration(for: profile))
        XCTAssertEqual(configuration.host, "100.64.0.8")
        XCTAssertEqual(configuration.port, 2200)
        XCTAssertEqual(configuration.username, "reader")
        XCTAssertEqual(settings.nvdaBridgeCommand(for: profile), "farrelay --ipc --host nvdaremote.com --port 6837 --channel 'relay channel'")
    }

    func testAppShellTabsHaveStableRequiredOrder() {
        XCTAssertEqual(AppShellTab.allCases, [.home, .nvda, .terminals, .agents, .assistant])
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "HostProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}

private final class TestCredentialStore: CredentialStore {
    private var values: [String: String] = [:]
    private let failWrites: Bool

    init(failWrites: Bool = false) {
        self.failWrites = failWrites
    }

    func string(for account: String) throws -> String? { values[account] }
    func store(_ value: String, for account: String) throws {
        if failWrites { throw TestStoreError.writeFailed }
        values[account] = value
    }
    func removeValue(for account: String) throws { values.removeValue(forKey: account) }
}

private enum TestStoreError: Error { case writeFailed }

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
