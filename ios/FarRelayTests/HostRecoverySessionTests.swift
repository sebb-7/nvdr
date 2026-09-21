import XCTest
@testable import FarRelay

@MainActor
final class HostRecoverySessionTests: XCTestCase {
    func testRecoveryUsesConfiguredHostCommandInsteadOfHardcodedPathLookup() throws {
        var profile = HostProfile(platform: .windows)
        profile.farRelayHostCommand = "  \"C:\\Program Files\\FarRelay\\farrelay-host.exe\"  "

        XCTAssertEqual(
            try HostRecoverySession.hostCommand(for: profile),
            "\"C:\\Program Files\\FarRelay\\farrelay-host.exe\""
        )
    }

    func testRecoveryHostCommandRejectsEmptyConfiguration() {
        var profile = HostProfile(platform: .windows)
        profile.farRelayHostCommand = "   "

        XCTAssertThrowsError(try HostRecoverySession.hostCommand(for: profile)) { error in
            XCTAssertEqual(
                error as? HostClientError,
                .hostError(
                    code: "invalid_host_command",
                    message: "The FarRelay Host command is empty."
                )
            )
        }
    }

    func testRecoveryHostCommandRejectsLineBreakInjection() {
        var profile = HostProfile(platform: .windows)
        profile.farRelayHostCommand = "farrelay-host\r\nwhoami"

        XCTAssertThrowsError(try HostRecoverySession.hostCommand(for: profile)) { error in
            XCTAssertEqual(
                error as? HostClientError,
                .hostError(
                    code: "invalid_host_command",
                    message: "The FarRelay Host command contains invalid control characters."
                )
            )
        }
    }

    func testRecoveryRestartRequiresVerifiedReadyTask() {
        XCTAssertFalse(RecoveryActionPolicy.canRestart(platform: .windows, status: nil, isWorking: false))
        XCTAssertFalse(
            RecoveryActionPolicy.canRestart(
                platform: .windows,
                status: NvdaRecoveryStatus(nvdaRunning: false, recoveryTaskReady: false),
                isWorking: false
            )
        )
        XCTAssertTrue(
            RecoveryActionPolicy.canRestart(
                platform: .windows,
                status: NvdaRecoveryStatus(nvdaRunning: false, recoveryTaskReady: true),
                isWorking: false
            )
        )
        XCTAssertFalse(
            RecoveryActionPolicy.canRestart(
                platform: .windows,
                status: NvdaRecoveryStatus(nvdaRunning: false, recoveryTaskReady: true),
                isWorking: true
            )
        )
        XCTAssertFalse(
            RecoveryActionPolicy.canRestart(
                platform: .macOS,
                status: NvdaRecoveryStatus(nvdaRunning: false, recoveryTaskReady: true),
                isWorking: false
            )
        )
    }

    func testRecoverySupportNeverDependsOnNVDAConfiguredRelayState() {
        let profile = HostProfile(
            address: "g14.example.test",
            username: "sebastian",
            platform: .windows,
            farRelayHostCommand: "farrelay-host",
            nvdaRemote: nil
        )
        let session = HostRecoverySession()
        session.configure(profile: profile, credentials: HostProfileCredentials(password: "test"))

        XCTAssertTrue(session.supportsAccessibilityRecovery)
        XCTAssertEqual(session.recoveryConnectionState, .ready)
    }
}
