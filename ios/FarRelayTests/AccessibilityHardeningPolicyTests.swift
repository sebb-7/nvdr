import XCTest
import UIKit
@testable import FarRelay

final class AccessibilityHardeningPolicyTests: XCTestCase {
    func testTerminalRowActionsFollowCapabilities() {
        let idle = TerminalSessionCapabilities(
            canPin: true,
            canUnpin: false,
            canRename: true,
            canRetry: false,
            canMoveUp: false,
            canMoveDown: true,
            canClose: true
        )
        XCTAssertEqual(
            TerminalSessionActionPolicy.actions(for: idle),
            [.pin, .rename, .moveDown, .close]
        )

        let failedPinned = TerminalSessionCapabilities(
            canPin: false,
            canUnpin: true,
            canRename: true,
            canRetry: true,
            canMoveUp: true,
            canMoveDown: false,
            canClose: true
        )
        XCTAssertEqual(
            TerminalSessionActionPolicy.actions(for: failedPinned),
            [.unpin, .rename, .retry, .moveUp, .close]
        )
    }

    func testComputerRowActionsNeverDuplicateRemoteControl() {
        var windows = HostProfile(displayName: "G14", platform: .windows)
        windows.nvdaRemote = NVDARemoteCapability(isEnabled: true, channel: "secret-channel")
        XCTAssertEqual(
            HostProfileActionPolicy.actions(for: windows),
            [.newTerminal, .edit, .delete]
        )

        var linux = HostProfile(displayName: "Box", platform: .linux)
        linux.nvdaRemote = NVDARemoteCapability(isEnabled: true, channel: "secret-channel")
        XCTAssertEqual(
            HostProfileActionPolicy.actions(for: linux),
            [.newTerminal, .edit, .delete]
        )

        let unconfigured = HostProfile(displayName: "G14", platform: .windows)
        XCTAssertEqual(
            HostProfileActionPolicy.actions(for: unconfigured),
            [.newTerminal, .edit, .delete]
        )
    }

    func testConversationActionsRemainCopyRunAgainAndOpenSnapshot() {
        let command = AccessibleConversationEntry(text: "ls", role: .outboundCommand)
        let output = AccessibleConversationEntry(text: "ok", role: .incomingContent)
        XCTAssertEqual(ConversationAccessibilityActionPolicy.actions(for: command), [.copy, .runAgain])
        XCTAssertEqual(ConversationAccessibilityActionPolicy.actions(for: output), [.copy, .openSnapshot])
    }

    func testTerminalConnectionAnnouncementsAreConciseAndSkipClosed() {
        XCTAssertEqual(
            ConnectionAnnouncementPolicy.terminalAnnouncement(
                from: .idle,
                to: .connecting,
                computerName: "G14"
            ),
            "Connecting to G14"
        )
        XCTAssertEqual(
            ConnectionAnnouncementPolicy.terminalAnnouncement(
                from: .connecting,
                to: .connected,
                computerName: "G14"
            ),
            "Connected to G14"
        )
        XCTAssertEqual(
            ConnectionAnnouncementPolicy.terminalAnnouncement(
                from: .connected,
                to: .ended,
                computerName: "G14"
            ),
            "Terminal disconnected"
        )
        XCTAssertNil(
            ConnectionAnnouncementPolicy.terminalAnnouncement(
                from: .idle,
                to: .closed,
                computerName: "G14"
            )
        )
        XCTAssertEqual(
            ConnectionAnnouncementPolicy.terminalAnnouncement(
                from: .connecting,
                to: .failed("auth failed"),
                computerName: "G14"
            ),
            "Connection failed: auth failed"
        )
    }

    func testNVDAAnnouncementsDeduplicateReconnectAttempts() {
        XCTAssertEqual(
            ConnectionAnnouncementPolicy.nvdaAnnouncement(
                from: .idle,
                to: .connecting,
                computerName: "G14"
            ),
            "Connecting to G14"
        )
        XCTAssertNil(
            ConnectionAnnouncementPolicy.nvdaAnnouncement(
                from: .connecting,
                to: .authenticating,
                computerName: "G14"
            )
        )
        XCTAssertEqual(
            ConnectionAnnouncementPolicy.nvdaAnnouncement(
                from: .connecting,
                to: .ready,
                computerName: "G14"
            ),
            "Connected to G14"
        )
        XCTAssertEqual(
            ConnectionAnnouncementPolicy.nvdaAnnouncement(
                from: .ready,
                to: .nvdaNotConnected,
                computerName: "G14"
            ),
            "Waiting for NVDA on G14"
        )
        XCTAssertNil(
            ConnectionAnnouncementPolicy.nvdaAnnouncement(
                from: .ready,
                to: .reconnecting(attempt: 1),
                computerName: "G14"
            )
        )
        XCTAssertNil(
            ConnectionAnnouncementPolicy.nvdaAnnouncement(
                from: .reconnecting(attempt: 1),
                to: .reconnecting(attempt: 2),
                computerName: "G14"
            )
        )
        XCTAssertEqual(
            ConnectionAnnouncementPolicy.nvdaAnnouncement(
                from: .reconnecting(attempt: 2),
                to: .failed(message: "boom"),
                computerName: "G14"
            ),
            "NVDA connection failed"
        )
    }

    func testForwardingAnnouncementIsExplicitToggleCopy() {
        XCTAssertEqual(
            NVDAForwardingAnnouncementPolicy.announcement(forEnabled: true),
            "Remote keyboard forwarding on"
        )
        XCTAssertEqual(
            NVDAForwardingAnnouncementPolicy.announcement(forEnabled: false),
            "Remote keyboard forwarding off"
        )
    }

    func testMissingCommandDiagnosticsDistinguishFarrelayFromHostProtocol() {
        let nvda = RemoteLaunchDiagnostics.nvdaFailureIssue(
            computerName: "G14",
            reason: "bash: farrelay: command not found",
            diagnosticText: "farrelay: bash: farrelay: command not found"
        )
        XCTAssertEqual(
            nvda.message,
            "The NVDA bridge command \"farrelay\" could not be started on G14."
        )

        let host = RemoteLaunchDiagnostics.terminalFailureIssue(
            computerName: "G14",
            reason: "farrelay-host: command not found",
            diagnosticText: "bash: farrelay-host: command not found",
            sessionID: UUID()
        )
        XCTAssertEqual(host.message, "farrelay-host could not be started on G14.")
        XCTAssertNotEqual(nvda.message, host.message)
    }

    func testAlertsUseReadableCopyAndRedactChannelSecrets() {
        let auth = RemoteLaunchDiagnostics.terminalFailureIssue(
            computerName: "G14",
            reason: "allAuthenticationOptionsFailed",
            diagnosticText: "auth failed for user",
            sessionID: UUID()
        )
        XCTAssertEqual(auth.title, "Unable to connect to G14")
        XCTAssertEqual(
            auth.message,
            "SSH authentication failed. Check this computer's saved key or password."
        )

        let opaque = RemoteLaunchDiagnostics.sanitizedReason("-1")
        XCTAssertEqual(
            opaque,
            "The connection failed. Check this computer's address, network, and credentials."
        )
        XCTAssertEqual(
            RemoteLaunchDiagnostics.sanitizedReason("Error -1"),
            "The connection failed. Check this computer's address, network, and credentials."
        )

        let diagnostic = RemoteLaunchDiagnostics.diagnosticText(
            computerName: "G14",
            address: "100.64.0.2",
            port: 22,
            username: "user",
            reason: "failed",
            logLines: [
                "farrelay --ipc --host nvdaremote.com --channel SECRETCHANNEL",
                "BEGIN OPENSSH PRIVATE KEY",
            ]
        )
        XCTAssertFalse(diagnostic.localizedStandardContains("SECRETCHANNEL"))
        XCTAssertTrue(diagnostic.localizedStandardContains("--channel •••"))
        XCTAssertFalse(diagnostic.localizedStandardContains("BEGIN OPENSSH PRIVATE KEY"))
        XCTAssertFalse(diagnostic.localizedStandardContains("passwordValue"))
    }

    func testReservedVoiceOverKeysAndPublicFunctionKeysMapThroughPriorityPolicy() {
        XCTAssertEqual(ReservedKeyForwardingPolicy.vk(forInput: UIKeyCommand.inputUpArrow), VK.up)
        XCTAssertEqual(ReservedKeyForwardingPolicy.vk(forInput: UIKeyCommand.inputDownArrow), VK.down)
        XCTAssertEqual(ReservedKeyForwardingPolicy.vk(forInput: UIKeyCommand.inputLeftArrow), VK.left)
        XCTAssertEqual(ReservedKeyForwardingPolicy.vk(forInput: UIKeyCommand.inputRightArrow), VK.right)
        XCTAssertEqual(ReservedKeyForwardingPolicy.vk(forInput: UIKeyCommand.inputEscape), VK.escape)
        XCTAssertEqual(ReservedKeyForwardingPolicy.vk(forInput: UIKeyCommand.f1), VK.f1)
        XCTAssertEqual(ReservedKeyForwardingPolicy.vk(forInput: UIKeyCommand.f12), VK.f1 + 11)
        XCTAssertNil(ReservedKeyForwardingPolicy.vk(forInput: "x"))
        XCTAssertEqual(ReservedKeyForwardingPolicy.registrations.count, 197)
    }

    func testPriorityFunctionChordReconstructsModifierDownKeyTapModifierUp() throws {
        let transitions = try XCTUnwrap(ReservedKeyForwardingPolicy.transitions(
            for: UIKeyCommand.f1,
            modifierFlags: [.shift, .control],
            optionMapping: .alt,
            commandMapping: .win
        ))

        XCTAssertEqual(
            transitions.map { "\($0.vk):\($0.pressed)" },
            ["17:true", "16:true", "112:true", "112:false", "16:false", "17:false"]
        )
    }

    func testPriorityChordUsesConfiguredOptionAndCommandMappings() throws {
        let transitions = try XCTUnwrap(ReservedKeyForwardingPolicy.transitions(
            for: UIKeyCommand.f1,
            modifierFlags: [.alternate, .command],
            optionMapping: .ctrl,
            commandMapping: .win
        ))

        XCTAssertEqual(
            transitions.map { "\($0.vk):\($0.pressed)" },
            ["162:true", "91:true", "112:true", "112:false", "91:false", "162:false"]
        )
    }

    func testPriorityDuplicateGateSuppressesMatchingRawChordWithoutStrandingReleases() {
        var gate = PriorityRawDuplicateGate()
        gate.recordPriorityTransitions([
            (vk: VK.shift, pressed: true),
            (vk: VK.f1, pressed: true),
            (vk: VK.f1, pressed: false),
            (vk: VK.shift, pressed: false)
        ])

        XCTAssertTrue(gate.suppressesRaw(vk: VK.lshift, pressed: true))
        XCTAssertTrue(gate.suppressesRaw(vk: VK.f1, pressed: true))
        XCTAssertTrue(gate.suppressesRaw(vk: VK.f1, pressed: false))
        XCTAssertTrue(gate.suppressesRaw(vk: VK.lshift, pressed: false))
        XCTAssertFalse(gate.suppressesRaw(vk: VK.f1, pressed: false))
    }

    func testDiagnosticsRedactEverySupportedShellArgumentForm() {
        let diagnostic = RemoteLaunchDiagnostics.redact(
            "farrelay --channel=first --password 'second value' --passphrase=third --channel fourth"
        )

        XCTAssertFalse(diagnostic.localizedStandardContains("first"))
        XCTAssertFalse(diagnostic.localizedStandardContains("second value"))
        XCTAssertFalse(diagnostic.localizedStandardContains("third"))
        XCTAssertFalse(diagnostic.localizedStandardContains("fourth"))
        XCTAssertEqual(diagnostic, "farrelay --channel=••• --password ••• --passphrase=••• --channel •••")
    }

    func testDeleteComputerConfirmationKeepsActiveTerminals() {
        XCTAssertEqual(
            HostProfileDeletionPolicy.confirmationMessage(computerName: "G14", activeTerminalCount: 0),
            "This removes G14 from Home."
        )
        XCTAssertEqual(
            HostProfileDeletionPolicy.confirmationMessage(computerName: "G14", activeTerminalCount: 1),
            "1 active terminal will remain open, but this computer will be removed from Home."
        )
        XCTAssertEqual(
            HostProfileDeletionPolicy.confirmationMessage(computerName: "G14", activeTerminalCount: 2),
            "2 active terminals will remain open, but this computer will be removed from Home."
        )
    }

    func testLooksLikeMissingExecutableDoesNotMatchOrdinaryNotConnectedCopy() {
        XCTAssertFalse(RemoteLaunchDiagnostics.looksLikeMissingExecutable("NVDA not connected on channel"))
        XCTAssertFalse(RemoteLaunchDiagnostics.looksLikeMissingExecutable("host not found"))
        XCTAssertTrue(RemoteLaunchDiagnostics.looksLikeMissingExecutable("command not found"))
    }
}
