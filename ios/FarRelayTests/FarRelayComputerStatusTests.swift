import XCTest
@testable import FarRelay

@MainActor
final class FarRelayComputerStatusTests: XCTestCase {
    func testInactiveProfilesDoNotInheritTheActiveComputerStatus() {
        let settings = testSettings()
        let active = configuredProfile(name: "Desk")
        let other = configuredProfile(name: "Laptop")
        let bridge = BridgeClient(speech: SpeechOutput())
        let terminals = TerminalSessionManager()

        bridge.start(settings: settings, profile: active)

        let status = FarRelayComputerStatus.derive(profile: other, bridge: bridge, terminals: terminals)
        XCTAssertEqual(status.connection, .disconnected)
        XCTAssertEqual(status.nvdaSummary, "NVDA not connected")
        XCTAssertEqual(status.connection.action, .connect)
    }

    func testFailureIsTruthfulAndOffersRetryInsteadOfDisconnect() {
        let profile = configuredProfile(name: "Desk")
        let bridge = BridgeClient(speech: SpeechOutput())
        let terminals = TerminalSessionManager()

        // This invalid profile causes the bridge to fail synchronously while
        // preserving the active profile identity for row derivation.
        var invalid = profile
        invalid.address = ""
        bridge.start(settings: testSettings(), profile: invalid)

        let status = FarRelayComputerStatus.derive(profile: invalid, bridge: bridge, terminals: terminals)
        XCTAssertEqual(status.connection.action, .connect)
        XCTAssertEqual(status.connection.label, "Connection failed")
        XCTAssertTrue(status.detail.localizedCaseInsensitiveContains("complete"))
    }

    func testConnectionActionsDistinguishCancelableAndEstablishedStates() {
        XCTAssertEqual(FarRelayComputerStatus.Connection.connecting.action, .cancel)
        XCTAssertEqual(FarRelayComputerStatus.Connection.reconnecting(2).action, .cancel)
        XCTAssertEqual(FarRelayComputerStatus.Connection.waitingForNVDA.action, .disconnect)
        XCTAssertEqual(FarRelayComputerStatus.Connection.ready.action, .disconnect)
    }

    private func configuredProfile(name: String) -> HostProfile {
        var profile = HostProfile(displayName: name, address: "host", username: "user", platform: .windows)
        profile.nvdaRemote = NVDARemoteCapability(isEnabled: true, channel: "test")
        return profile
    }

    private func testSettings() -> AppSettings {
        let suite = "FarRelayComputerStatusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }
}
