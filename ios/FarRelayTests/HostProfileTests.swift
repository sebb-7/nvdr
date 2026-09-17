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

    func testSavingProfileNormalizesRelayConfigurationWithoutExposingChannel() throws {
        let defaults = try makeDefaults()
        let credentials = TestCredentialStore()
        let settings = AppSettings(defaults: defaults, credentialStore: credentials)
        let profile = HostProfile(
            address: "relay.example",
            username: "reader",
            platform: .windows,
            nvdaRemote: NVDARemoteCapability(
                isEnabled: true,
                relayHost: " relay.example \n",
                channel: "123456789 \n",
                fingerprint: " abcd \n"
            )
        )

        XCTAssertTrue(settings.saveProfile(profile, credentials: HostProfileCredentials(password: "pw")))
        let saved = try XCTUnwrap(settings.hostProfiles.only)
        XCTAssertEqual(saved.nvdaRemote?.relayHost, "relay.example")
        XCTAssertEqual(saved.nvdaRemote?.channel, "123456789")
        XCTAssertEqual(saved.nvdaRemote?.fingerprint, "abcd")
        let command = try XCTUnwrap(settings.nvdaBridgeCommand(for: saved))
        XCTAssertTrue(command.contains("--channel 123456789"))
        XCTAssertTrue(command.contains("--channel 123456789 --fingerprint abcd"))
        XCTAssertFalse(command.contains("\n"))
    }

    func testBuild5MigrationPreservesCompletePasswordAndNVDAConfiguration() throws {
        let defaults = try makeDefaults()
        defaults.set("build5.example.test", forKey: "farrelay.sshHost")
        defaults.set(2202, forKey: "farrelay.sshPort")
        defaults.set("legacy-reader", forKey: "farrelay.sshUser")
        defaults.set("password", forKey: "farrelay.sshAuthMode")
        defaults.set("farrelay", forKey: "farrelay.remoteCommand")
        defaults.set("relay.example.test", forKey: "farrelay.relayHost")
        defaults.set(7001, forKey: "farrelay.relayPort")
        defaults.set("test-channel", forKey: "farrelay.channel")
        defaults.set("test-fingerprint", forKey: "farrelay.fingerprint")
        defaults.set(true, forKey: "farrelay.insecure")
        let credentials = TestCredentialStore()
        try credentials.store("test-password", for: SSHCredential.password.account)

        let settings = AppSettings(defaults: defaults, credentialStore: credentials)
        let profile = try XCTUnwrap(settings.hostProfiles.only)
        XCTAssertEqual(profile.address, "build5.example.test")
        XCTAssertEqual(profile.port, 2202)
        XCTAssertEqual(profile.username, "legacy-reader")
        XCTAssertEqual(profile.authenticationMode, .password)
        XCTAssertEqual(profile.farRelayHostCommand, "farrelay-host")
        XCTAssertEqual(profile.nvdaBridgeCommand, "farrelay")
        XCTAssertEqual(profile.platform, .windows)
        XCTAssertEqual(
            profile.nvdaRemote,
            NVDARemoteCapability(
                isEnabled: true,
                relayHost: "relay.example.test",
                relayPort: 7001,
                channel: "test-channel",
                fingerprint: "test-fingerprint",
                insecure: true
            )
        )
        XCTAssertEqual(settings.credentials(for: profile)?.password, "test-password")
        XCTAssertNil(try credentials.string(for: SSHCredential.password.account))

        let profileJSON = try XCTUnwrap(String(data: JSONEncoder().encode(profile), encoding: .utf8))
        XCTAssertFalse(profileJSON.contains("test-password"))
        XCTAssertEqual(AppSettings(defaults: defaults, credentialStore: credentials).hostProfiles, [profile])
    }

    func testBuild5MigrationPreservesPrivateKeyAndPartialSSHConfiguration() throws {
        let defaults = try makeDefaults()
        defaults.set("partial.example.test", forKey: "farrelay.sshHost")
        defaults.set("privateKey", forKey: "farrelay.sshAuthMode")
        let credentials = TestCredentialStore()
        try credentials.store("test-private-key", for: SSHCredential.privateKey.account)
        try credentials.store("test-passphrase", for: SSHCredential.privateKeyPassphrase.account)

        let settings = AppSettings(defaults: defaults, credentialStore: credentials)
        let profile = try XCTUnwrap(settings.hostProfiles.only)
        XCTAssertEqual(profile.address, "partial.example.test")
        XCTAssertEqual(profile.port, 22)
        XCTAssertEqual(profile.username, "")
        XCTAssertEqual(profile.authenticationMode, .privateKey)
        XCTAssertNil(profile.nvdaRemote)
        XCTAssertEqual(
            settings.credentials(for: profile),
            HostProfileCredentials(
                password: "",
                privateKeyPEM: "test-private-key",
                privateKeyPassphrase: "test-passphrase"
            )
        )

        let profileJSON = try XCTUnwrap(String(data: JSONEncoder().encode(profile), encoding: .utf8))
        XCTAssertFalse(profileJSON.contains("test-private-key"))
        XCTAssertFalse(profileJSON.contains("test-passphrase"))
    }

    func testStaleLegacySSHKeysDoNotOverwriteAnExistingModernProfile() throws {
        let defaults = try makeDefaults()
        let modern = HostProfile(
            displayName: "Modern G14",
            address: "modern.example.test",
            port: 2222,
            username: "modern-reader",
            authenticationMode: .privateKey,
            platform: .windows
        )
        saveHostProfiles([modern], defaults: defaults)
        defaults.set("stale.example.test", forKey: "farrelay.sshHost")
        defaults.set("stale-reader", forKey: "farrelay.sshUser")
        defaults.set("stale-password", forKey: SSHCredential.password.legacyDefaultsKey)
        let credentials = TestCredentialStore()
        try credentials.store("modern-private-key", for: HostProfileCredential.privateKey.account(for: modern.id))

        let settings = AppSettings(defaults: defaults, credentialStore: credentials)
        XCTAssertEqual(settings.hostProfiles, [modern])
        XCTAssertEqual(settings.credentials(for: modern)?.privateKeyPEM, "modern-private-key")
        XCTAssertEqual(defaults.string(forKey: "farrelay.sshHost"), "stale.example.test")
        XCTAssertEqual(defaults.string(forKey: SSHCredential.password.legacyDefaultsKey), "stale-password")
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
        let profile = HostProfile(
            displayName: "Tailscale is just SSH",
            address: "100.64.0.8",
            port: 2200,
            username: "reader",
            platform: .windows,
            farRelayHostCommand: "farrelay-host",
            nvdaBridgeCommand: "farrelay",
            nvdaRemote: NVDARemoteCapability(isEnabled: true, channel: "relay channel")
        )
        XCTAssertTrue(profile.isNVDARemoteEnabled)
        XCTAssertTrue(settings.saveProfile(profile, credentials: HostProfileCredentials(password: "secret")))
        let configuration = try XCTUnwrap(settings.sshSessionConfiguration(for: profile))
        XCTAssertEqual(configuration.host, "100.64.0.8")
        XCTAssertEqual(configuration.port, 2200)
        XCTAssertEqual(configuration.username, "reader")
        let command = try XCTUnwrap(settings.nvdaBridgeCommand(for: profile))
        XCTAssertEqual(command, "farrelay --ipc --host nvdaremote.com --port 6837 --channel 'relay channel'")
        XCTAssertFalse(command.contains("farrelay-host"))
        XCTAssertNotEqual(profile.farRelayHostCommand, profile.nvdaBridgeCommand)
    }

    func testAppShellTabsHaveStableRequiredOrder() {
        XCTAssertEqual(AppShellTab.allCases, [.home, .remoteControl, .terminals, .agents, .assistant])
        XCTAssertEqual(AppShellTab.allCases.map(\.rawValue), ["home", "remoteControl", "terminals", "agents", "assistant"])
        XCTAssertFalse(AppShellTab.allCases.map(\.rawValue).contains("nvda"))
        XCTAssertFalse(AppShellTab.allCases.map(\.rawValue).contains("settings"))
    }

    func testWindowsOrientedModifierDefaultsAndExplicitPreference() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults, credentialStore: TestCredentialStore())
        XCTAssertEqual(settings.optionMapping, .win)
        XCTAssertEqual(settings.commandMapping, .win)

        defaults.set(ModifierMapping.ctrl.rawValue, forKey: "farrelay.commandMapping")
        let reloaded = AppSettings(defaults: defaults, credentialStore: TestCredentialStore())
        XCTAssertEqual(reloaded.commandMapping, .ctrl)
    }

    func testHostProfileWithoutPlatformFieldDecodesAsOther() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","displayName":"G14","address":"host.example","port":22,"username":"reader","authenticationMode":"password"}
        """
        let decoded = try JSONDecoder().decode(HostProfile.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.platform, .other)
        XCTAssertEqual(decoded.farRelayHostCommand, "farrelay-host")
        XCTAssertEqual(decoded.nvdaBridgeCommand, "farrelay")
        XCTAssertNil(decoded.nvdaRemote)
        XCTAssertFalse(decoded.isNVDARemoteEnabled)
    }

    func testPlatformRoundTripAndEditPreserveProfileIdentity() throws {
        let original = HostProfile(displayName: "G14", address: "g14", username: "user", platform: .linux)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: encoded)
        XCTAssertEqual(decoded.platform, .linux)
        XCTAssertEqual(decoded.id, original.id)

        var edited = decoded
        edited.platform = .windows
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.platform, .windows)
        let credentials = HostProfileCredentials(password: "pw")
        let before = original.sshSessionConfiguration(credentials: credentials)
        let after = edited.sshSessionConfiguration(credentials: credentials)
        XCTAssertEqual(before.host, after.host)
        XCTAssertEqual(before.port, after.port)
        XCTAssertEqual(before.username, after.username)
    }

    func testNVDARemoteCapabilityIsOptionalAndWindowsOnly() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults, credentialStore: TestCredentialStore())
        let unset = HostProfile(platform: .windows)
        XCTAssertNil(unset.nvdaRemote)
        XCTAssertFalse(unset.isNVDARemoteEnabled)
        XCTAssertNil(settings.nvdaBridgeCommand(for: unset))

        let windows = HostProfile(
            platform: .windows,
            nvdaRemote: NVDARemoteCapability(isEnabled: true, relayHost: "relay.example", relayPort: 7001, channel: "chan")
        )
        XCTAssertTrue(windows.isNVDARemoteEnabled)
        XCTAssertEqual(
            settings.nvdaBridgeCommand(for: windows),
            "farrelay --ipc --host relay.example --port 7001 --channel chan"
        )

        let linux = HostProfile(
            platform: .linux,
            nvdaRemote: NVDARemoteCapability(isEnabled: true, channel: "chan")
        )
        XCTAssertFalse(linux.isNVDARemoteEnabled)
        XCTAssertNil(settings.nvdaBridgeCommand(for: linux))
    }

    func testEmptyLegacyNVDAChannelDoesNotEnableCapability() throws {
        let defaults = try makeDefaults()
        let first = HostProfile(displayName: "First", address: "first", username: "user")
        saveHostProfiles([first], defaults: defaults)
        defaults.set("nvdaremote.com", forKey: "farrelay.relayHost")
        defaults.set(6837, forKey: "farrelay.relayPort")
        defaults.set("", forKey: "farrelay.channel")
        defaults.set("sha-256-fp", forKey: "farrelay.fingerprint")
        defaults.set(true, forKey: "farrelay.insecure")

        let settings = AppSettings(defaults: defaults, credentialStore: TestCredentialStore())
        let profile = try XCTUnwrap(settings.hostProfiles.only)
        XCTAssertEqual(profile.id, first.id)
        XCTAssertNil(profile.nvdaRemote)
        XCTAssertFalse(profile.isNVDARemoteEnabled)
        XCTAssertEqual(profile.platform, .other)
        XCTAssertTrue(defaults.bool(forKey: "farrelay.nvdaCapabilityMigrationComplete"))
        XCTAssertNil(defaults.object(forKey: "farrelay.relayHost"))
        XCTAssertNil(defaults.object(forKey: "farrelay.channel"))
        XCTAssertNil(defaults.object(forKey: "farrelay.fingerprint"))
    }

    func testWhitespaceLegacyNVDAChannelDoesNotEnableCapability() throws {
        let defaults = try makeDefaults()
        saveHostProfiles([HostProfile(displayName: "First", address: "first", username: "user")], defaults: defaults)
        defaults.set("   \t", forKey: "farrelay.channel")
        defaults.set("nvdaremote.com", forKey: "farrelay.relayHost")

        let settings = AppSettings(defaults: defaults, credentialStore: TestCredentialStore())
        XCTAssertNil(try XCTUnwrap(settings.hostProfiles.only).nvdaRemote)
        XCTAssertTrue(defaults.bool(forKey: "farrelay.nvdaCapabilityMigrationComplete"))
    }

    func testConfiguredLegacyNVDAMigratesOntoSelectedProfileOnce() throws {
        let defaults = try makeDefaults()
        let first = HostProfile(displayName: "Mac mini", address: "mac", username: "user", platform: .macOS)
        let second = HostProfile(displayName: "G14", address: "g14", username: "user", platform: .other)
        saveHostProfiles([first, second], defaults: defaults)
        defaults.set(second.id.uuidString, forKey: "farrelay.selectedNVDAProfileID")
        defaults.set("relay.example", forKey: "farrelay.relayHost")
        defaults.set(7001, forKey: "farrelay.relayPort")
        defaults.set("channel-key", forKey: "farrelay.channel")
        defaults.set("pinned-fp", forKey: "farrelay.fingerprint")
        defaults.set(true, forKey: "farrelay.insecure")

        let settings = AppSettings(defaults: defaults, credentialStore: TestCredentialStore())
        XCTAssertEqual(settings.hostProfiles.count, 2)
        XCTAssertNil(settings.hostProfiles.first { $0.id == first.id }?.nvdaRemote)
        let migrated = try XCTUnwrap(settings.hostProfiles.first { $0.id == second.id })
        XCTAssertEqual(migrated.platform, .windows)
        let capability = try XCTUnwrap(migrated.nvdaRemote)
        XCTAssertTrue(capability.isEnabled)
        XCTAssertEqual(capability.relayHost, "relay.example")
        XCTAssertEqual(capability.relayPort, 7001)
        XCTAssertEqual(capability.channel, "channel-key")
        XCTAssertEqual(capability.fingerprint, "pinned-fp")
        XCTAssertTrue(capability.insecure)
        XCTAssertTrue(migrated.isNVDARemoteEnabled)
        XCTAssertNil(defaults.object(forKey: "farrelay.channel"))
        XCTAssertNil(defaults.object(forKey: "farrelay.selectedNVDAProfileID"))
        XCTAssertTrue(defaults.bool(forKey: "farrelay.nvdaCapabilityMigrationComplete"))

        let reloaded = AppSettings(defaults: defaults, credentialStore: TestCredentialStore())
        XCTAssertEqual(reloaded.hostProfiles, settings.hostProfiles)
        XCTAssertEqual(reloaded.hostProfiles.filter { $0.nvdaRemote != nil }.count, 1)
    }

    func testLegacyNVDAMigrationChoosesFirstProfileWhenSelectionIsMissing() throws {
        let defaults = try makeDefaults()
        let first = HostProfile(displayName: "First", address: "first", username: "user")
        let second = HostProfile(displayName: "Second", address: "second", username: "user")
        saveHostProfiles([first, second], defaults: defaults)
        defaults.set(UUID().uuidString, forKey: "farrelay.selectedNVDAProfileID")
        defaults.set("channel-key", forKey: "farrelay.channel")
        defaults.set("relay.example", forKey: "farrelay.relayHost")

        let settings = AppSettings(defaults: defaults, credentialStore: TestCredentialStore())
        XCTAssertEqual(settings.hostProfiles[0].nvdaRemote?.channel, "channel-key")
        XCTAssertEqual(settings.hostProfiles[0].platform, .windows)
        XCTAssertNil(settings.hostProfiles[1].nvdaRemote)
        XCTAssertNil(defaults.object(forKey: "farrelay.selectedNVDAProfileID"))
    }

    func testLegacyNVDAMigrationDoesNotOverwriteExistingCapability() throws {
        let defaults = try makeDefaults()
        let existing = NVDARemoteCapability(isEnabled: true, relayHost: "already.example", channel: "kept")
        let first = HostProfile(displayName: "G14", address: "g14", username: "user", platform: .windows, nvdaRemote: existing)
        saveHostProfiles([first], defaults: defaults)
        defaults.set("new.relay", forKey: "farrelay.relayHost")
        defaults.set("new-channel", forKey: "farrelay.channel")

        let settings = AppSettings(defaults: defaults, credentialStore: TestCredentialStore())
        let profile = try XCTUnwrap(settings.hostProfiles.only)
        XCTAssertEqual(profile.nvdaRemote?.channel, "kept")
        XCTAssertEqual(profile.nvdaRemote?.relayHost, "already.example")
        XCTAssertTrue(defaults.bool(forKey: "farrelay.nvdaCapabilityMigrationComplete"))
    }

    func testHostProfileJSONNeverContainsCredentialSecrets() throws {
        var profile = HostProfile(platform: .windows)
        profile.nvdaRemote = NVDARemoteCapability(isEnabled: true, channel: "relay-channel")
        let encoded = try JSONEncoder().encode(profile)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertFalse(text.contains("passwordValue"))
        XCTAssertFalse(text.contains("BEGIN PRIVATE KEY"))
        XCTAssertTrue(text.contains("relay-channel"))
        XCTAssertTrue(text.contains("farrelay-host"))
        XCTAssertTrue(text.contains("farrelay"))
    }

    func testLeavingNVDAHostContextSuspendsKeyboardForwarding() {
        let bridge = BridgeClient(speech: SpeechOutput())
        bridge.forwardingEnabled = true
        bridge.suspendInputForInactiveContext()
        XCTAssertFalse(bridge.forwardingEnabled)
        XCTAssertFalse(bridge.isInputForwardingReady)
    }

    func testIPCParserKeepsRelayAndNVDAReadinessDistinct() {
        XCTAssertEqual(IPCParser.parse("state relay_connected"), .state(.relayConnected))
        XCTAssertEqual(IPCParser.parse("state waiting_for_nvda"), .state(.waitingForNVDA))
        XCTAssertEqual(IPCParser.parse("state ready"), .state(.ready))
    }

    func testFailedProfileSaveDoesNotPersistAProfile() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults, credentialStore: TestCredentialStore(failWrites: true))
        let profile = HostProfile(displayName: "Unsaved", address: "host", username: "user")

        XCTAssertFalse(settings.saveProfile(profile, credentials: HostProfileCredentials(password: "pw")))
        XCTAssertTrue(settings.hostProfiles.isEmpty)
        XCTAssertNotNil(settings.credentialStorageError)
    }

    func testMalformedProfileDataIsReportedWithoutOverwritingRecoveryBytes() throws {
        let defaults = try makeDefaults()
        let corrupted = Data("{ definitely not a profile array }".utf8)
        defaults.set(corrupted, forKey: "farrelay.hostProfiles")

        let settings = AppSettings(defaults: defaults, credentialStore: TestCredentialStore())

        XCTAssertTrue(settings.hostProfiles.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "farrelay.hostProfiles"), corrupted)
        XCTAssertEqual(
            settings.credentialStorageError,
            "Saved computer metadata was unreadable and was preserved for recovery."
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "HostProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func saveHostProfiles(_ profiles: [HostProfile], defaults: UserDefaults) {
        HostProfileStore(defaults: defaults, key: "farrelay.hostProfiles").save(profiles)
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
