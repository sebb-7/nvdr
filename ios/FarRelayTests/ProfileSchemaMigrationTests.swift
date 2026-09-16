import XCTest
@testable import FarRelay

@MainActor
final class ProfileSchemaMigrationTests: XCTestCase {
    func testLegacyProfileBytesMigrateDeterministicallyAndPreserveSource() throws {
        let defaults = try makeDefaults()
        let profile = HostProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            displayName: "G14",
            address: "100.64.0.2",
            username: "reader",
            platform: .windows,
            nvdaRemote: NVDARemoteCapability(isEnabled: true, relayHost: "relay.example", channel: "fixture-channel")
        )
        let oldBytes = try JSONEncoder().encode([profile])
        defaults.set(oldBytes, forKey: "farrelay.hostProfiles")

        let settings = AppSettings(defaults: defaults, credentialStore: MigrationCredentialStore())
        XCTAssertEqual(settings.hostProfiles, [profile])
        XCTAssertEqual(defaults.data(forKey: "farrelay.hostProfiles.migrationSource"), oldBytes)
        let current = try XCTUnwrap(defaults.data(forKey: "farrelay.hostProfiles"))
        XCTAssertNotEqual(current, oldBytes)
        XCTAssertEqual(HostProfileStore(defaults: defaults, key: "farrelay.hostProfiles").load(), .profiles([profile]))
    }

    func testUnknownFutureSchemaIsPreservedAndNotReplaced() throws {
        let defaults = try makeDefaults()
        let bytes = Data("{\"schemaVersion\":99,\"profiles\":[]}".utf8)
        defaults.set(bytes, forKey: "farrelay.hostProfiles")

        let settings = AppSettings(defaults: defaults, credentialStore: MigrationCredentialStore())
        XCTAssertTrue(settings.hostProfiles.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "farrelay.hostProfiles"), bytes)
        XCTAssertTrue(settings.credentialStorageError?.contains("newer unsupported") == true)
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "ProfileSchemaMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}

private final class MigrationCredentialStore: CredentialStore {
    func string(for account: String) throws -> String? { nil }
    func store(_ value: String, for account: String) throws {}
    func removeValue(for account: String) throws {}
}
