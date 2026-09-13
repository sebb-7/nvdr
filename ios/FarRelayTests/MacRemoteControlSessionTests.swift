import Foundation
import XCTest
@testable import FarRelay

@MainActor
final class MacRemoteControlSessionTests: XCTestCase {
    func testSemanticActionIDsAndProvisionalMappingsAreStable() {
        XCTAssertEqual(MacRemoteControlAction.previousItem.id, "previousItem")
        XCTAssertEqual(MacRemoteControlAction.nextItem.id, "nextItem")
        XCTAssertEqual(MacRemoteControlAction.moveUp.id, "moveUp")
        XCTAssertEqual(MacRemoteControlAction.moveDown.id, "moveDown")
        XCTAssertEqual(MacRemoteControlAction.interact.id, "interact")
        XCTAssertEqual(MacRemoteControlAction.stopInteracting.id, "stopInteracting")
        XCTAssertEqual(MacRemoteControlAction.activate.id, "activate")
        XCTAssertEqual(MacRemoteControlAction.refreshState.id, "refreshState")
        XCTAssertEqual(MacRemoteControlAction.previousItem.moveDirection, .left)
        XCTAssertEqual(MacRemoteControlAction.nextItem.moveDirection, .right)
        XCTAssertEqual(MacRemoteControlAction.moveUp.moveDirection, .up)
        XCTAssertEqual(MacRemoteControlAction.moveDown.moveDirection, .down)
        XCTAssertEqual(MacRemoteControlAction.interact.moveDirection, .into)
        XCTAssertEqual(MacRemoteControlAction.stopInteracting.moveDirection, .out)
        XCTAssertNil(MacRemoteControlAction.activate.moveDirection)
        XCTAssertNil(MacRemoteControlAction.refreshState.moveDirection)
        XCTAssertEqual(MacRemoteControlAction.allCases.map(\.buttonTitle), [
            "Previous", "Next", "Up", "Down", "Interact", "Stop Interacting", "Activate", "Refresh",
        ])
    }

    func testNonMacOSProfilesDoNotExposeRemoteControl() {
        XCTAssertFalse(HostProfile(platform: .windows).exposesMacRemoteControl)
        XCTAssertFalse(HostProfile(platform: .linux).exposesMacRemoteControl)
        XCTAssertFalse(HostProfile(platform: .other).exposesMacRemoteControl)
    }

    func testMacOSProfilesExposeRemoteControlWithoutMarkingItReady() {
        let profile = macProfile()
        let session = MacRemoteControlSession(
            connectionFactory: FakeMacRemoteControlConnectionFactory(clients: [FakeVoiceOverHostClient()])
        )
        XCTAssertTrue(profile.exposesMacRemoteControl)
        XCTAssertEqual(session.phase, .disconnected)
        XCTAssertFalse(session.controlsEnabled)
        XCTAssertEqual(session.statusText, "Disconnected")
    }

    func testConnectRejectsNonMacOSAndIncompleteProfiles() async {
        let factory = FakeMacRemoteControlConnectionFactory(clients: [FakeVoiceOverHostClient()])
        let session = MacRemoteControlSession(connectionFactory: factory)

        await session.connect(profile: HostProfile(platform: .windows, address: "g14", username: "user"), configuration: configuration())
        XCTAssertEqual(session.phase, .failed("Remote Control is available only for macOS computers."))
        XCTAssertEqual(await factory.openCount(), 0)

        await session.connect(profile: HostProfile(platform: .macOS, address: "", username: "user"), configuration: configuration())
        XCTAssertEqual(session.phase, .failed("Select a complete macOS computer before connecting."))
        XCTAssertEqual(await factory.openCount(), 0)
        XCTAssertFalse(session.controlsEnabled)
    }

    func testConnectUsesProfileScopedSSHConfigurationAndHostCommand() async {
        let client = FakeVoiceOverHostClient()
        let factory = FakeMacRemoteControlConnectionFactory(clients: [client])
        let session = MacRemoteControlSession(connectionFactory: factory)
        var profile = macProfile(address: "macmini.example", port: 2200, username: "reader")
        profile.farRelayHostCommand = "/usr/local/bin/farrelay-host"

        await session.connect(profile: profile, configuration: configuration(
            host: "macmini.example",
            port: 2200,
            username: "reader"
        ))

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.usedHostCommand, "/usr/local/bin/farrelay-host")
        XCTAssertEqual(session.usedConfiguration?.host, "macmini.example")
        XCTAssertEqual(session.usedConfiguration?.port, 2200)
        XCTAssertEqual(session.usedConfiguration?.username, "reader")
        XCTAssertEqual(await factory.hostCommands(), ["/usr/local/bin/farrelay-host"])
        XCTAssertEqual(await factory.hosts(), ["macmini.example"])
        XCTAssertEqual(await factory.ports(), [2200])
        XCTAssertEqual(await factory.usernames(), ["reader"])
        await session.disconnect()
    }

    func testDefaultAndEmptyHostCommandsResolveToFarRelayHost() async {
        let first = FakeVoiceOverHostClient()
        let second = FakeVoiceOverHostClient()
        let factory = FakeMacRemoteControlConnectionFactory(clients: [first, second])
        let session = MacRemoteControlSession(connectionFactory: factory)

        var defaultProfile = macProfile()
        defaultProfile.farRelayHostCommand = "farrelay-host"
        await session.connect(profile: defaultProfile, configuration: configuration())
        XCTAssertEqual(session.usedHostCommand, "farrelay-host")

        await session.disconnect()
        var emptyProfile = macProfile()
        emptyProfile.farRelayHostCommand = "  \t"
        await session.connect(profile: emptyProfile, configuration: configuration())
        XCTAssertEqual(session.usedHostCommand, "farrelay-host")
        XCTAssertEqual(FarRelayHostConnection.defaultCommand, "farrelay-host")
        XCTAssertEqual(FarRelayHostConnection.command, "farrelay-host")
        XCTAssertEqual(await factory.hostCommands(), ["farrelay-host", "farrelay-host"])
        await session.disconnect()
    }

    func testConnectUsesAppSettingsProfileCredentials() async throws {
        let client = FakeVoiceOverHostClient()
        let factory = FakeMacRemoteControlConnectionFactory(clients: [client])
        let session = MacRemoteControlSession(connectionFactory: factory)
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults, credentialStore: TestRemoteControlCredentialStore())
        let profile = macProfile(address: "mini.local", port: 22, username: "vo")
        XCTAssertTrue(settings.saveProfile(profile, credentials: HostProfileCredentials(password: "secret")))

        await session.connect(settings: settings, profile: profile)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(await factory.hosts(), ["mini.local"])
        XCTAssertEqual(await factory.usernames(), ["vo"])
        await session.disconnect()
    }

    func testMissingVoiceOverOperationsIsUnsupportedAndDoesNotCallThem() async {
        let client = FakeVoiceOverHostClient(
            capabilities: HostCapabilities(
                protocolVersion: 1,
                hostImplementation: "farrelay-host",
                hostVersion: "0.1.0",
                operations: ["host.info", "process.list", "process.info"]
            )
        )
        let factory = FakeMacRemoteControlConnectionFactory(clients: [client])
        let session = MacRemoteControlSession(connectionFactory: factory)

        await session.connect(profile: macProfile(), configuration: configuration())
        XCTAssertEqual(session.phase, .unsupportedHost)
        XCTAssertFalse(session.controlsEnabled)
        XCTAssertEqual(await client.operations(), ["capabilities"])
        await session.disconnect()
    }

    func testUnavailableVoiceOverStatusDoesNotBecomeReady() async {
        let client = FakeVoiceOverHostClient(
            status: VoiceOverStatus(
                platformSupported: true,
                available: false,
                voiceOverRunning: false,
                appleScriptBridgeUsable: false,
                message: "VoiceOver is not running."
            )
        )
        let session = MacRemoteControlSession(
            connectionFactory: FakeMacRemoteControlConnectionFactory(clients: [client])
        )

        await session.connect(profile: macProfile(), configuration: configuration())
        XCTAssertEqual(session.phase, .unavailable)
        XCTAssertEqual(session.voiceOverStatusText, "VoiceOver is not running.")
        XCTAssertFalse(session.controlsEnabled)
        XCTAssertEqual(await client.operations(), ["capabilities", "voiceover.status"])
        await session.disconnect()
    }

    func testUsableStatusReachesReadyAndFetchesInitialState() async {
        let client = FakeVoiceOverHostClient(
            state: VoiceOverState(
                lastSpokenPhrase: "Safari",
                voiceOverCursorText: "Search field",
                keyboardCursorText: nil
            )
        )
        let session = MacRemoteControlSession(
            connectionFactory: FakeMacRemoteControlConnectionFactory(clients: [client])
        )

        await session.connect(profile: macProfile(), configuration: configuration())
        XCTAssertEqual(session.phase, .ready)
        XCTAssertTrue(session.controlsEnabled)
        XCTAssertEqual(session.voiceOverStatusText, "Ready")
        XCTAssertEqual(session.lastSpokenPhraseText, "Safari")
        XCTAssertEqual(session.voiceOverCursorText, "Search field")
        XCTAssertNil(session.keyboardCursorText)
        XCTAssertEqual(await client.operations(), ["capabilities", "voiceover.status", "voiceover.state"])
        await session.disconnect()
    }

    func testSemanticActionsMapToHostOperationsAndRefreshState() async {
        let client = FakeVoiceOverHostClient()
        let session = MacRemoteControlSession(
            connectionFactory: FakeMacRemoteControlConnectionFactory(clients: [client])
        )
        await session.connect(profile: macProfile(), configuration: configuration())
        await client.resetOperations()

        await session.perform(.previousItem)
        await session.perform(.nextItem)
        await session.perform(.moveUp)
        await session.perform(.moveDown)
        await session.perform(.interact)
        await session.perform(.stopInteracting)
        await session.perform(.activate)
        await session.perform(.refreshState)

        XCTAssertEqual(await client.operations(), [
            "move.left", "voiceover.state",
            "move.right", "voiceover.state",
            "move.up", "voiceover.state",
            "move.down", "voiceover.state",
            "move.into", "voiceover.state",
            "move.out", "voiceover.state",
            "voiceover.press", "voiceover.state",
            "voiceover.state",
        ])
        XCTAssertNil(session.lastActionError)
        await session.disconnect()
    }

    func testStateRefreshFailureDoesNotRewriteSuccessfulAction() async {
        let client = FakeVoiceOverHostClient()
        await client.setStateError(HostClientError.hostError(code: "internal_error", message: "state probe failed"))
        let session = MacRemoteControlSession(
            connectionFactory: FakeMacRemoteControlConnectionFactory(clients: [client])
        )
        await session.connect(profile: macProfile(), configuration: configuration())
        XCTAssertEqual(session.phase, .ready)
        XCTAssertNotNil(session.lastStateRefreshError)
        await client.setStateError(nil)
        await client.resetOperations()
        await client.setFailStateAfterMoves(true)

        await session.perform(.nextItem)
        XCTAssertEqual(session.lastCompletedAction, .nextItem)
        XCTAssertNil(session.lastActionError)
        XCTAssertEqual(
            session.lastStateRefreshError,
            "Unable to refresh VoiceOver state: FarRelay Host error internal_error: state probe failed"
        )
        XCTAssertEqual(await client.operations(), ["move.right", "voiceover.state"])
        await session.disconnect()
    }

    func testActionFailureIsSurfacedTruthfully() async {
        let client = FakeVoiceOverHostClient()
        await client.setMoveError(HostClientError.hostError(
            code: "voiceover_control_unavailable",
            message: "VoiceOver AppleScript control is not currently usable"
        ))
        let session = MacRemoteControlSession(
            connectionFactory: FakeMacRemoteControlConnectionFactory(clients: [client])
        )
        await session.connect(profile: macProfile(), configuration: configuration())
        await client.resetOperations()

        await session.perform(.nextItem)
        XCTAssertEqual(
            session.lastActionError,
            "Next failed: FarRelay Host error voiceover_control_unavailable: VoiceOver AppleScript control is not currently usable"
        )
        XCTAssertNil(session.lastStateRefreshError)
        XCTAssertEqual(await client.operations(), ["move.right"])
        await session.disconnect()
    }

    func testActionsExecuteInDeterministicOrder() async {
        let client = FakeVoiceOverHostClient()
        await client.blockNextMove()
        let session = MacRemoteControlSession(
            connectionFactory: FakeMacRemoteControlConnectionFactory(clients: [client])
        )
        await session.connect(profile: macProfile(), configuration: configuration())
        await client.resetOperations()

        async let first: Void = session.perform(.nextItem)
        await waitUntil { await client.moveCount() == 1 }
        async let second: Void = session.perform(.previousItem)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(await client.operations(), ["move.right"])
        await client.unblockMoves()
        await first
        await second
        XCTAssertEqual(await client.operations(), [
            "move.right", "voiceover.state",
            "move.left", "voiceover.state",
        ])
        await session.disconnect()
    }

    func testControlsAreUnavailableBeforeReadyAndAfterDisconnect() async {
        let client = FakeVoiceOverHostClient()
        let session = MacRemoteControlSession(
            connectionFactory: FakeMacRemoteControlConnectionFactory(clients: [client])
        )
        await session.perform(.nextItem)
        XCTAssertEqual(await client.operations(), [])
        XCTAssertFalse(session.controlsEnabled)

        await session.connect(profile: macProfile(), configuration: configuration())
        XCTAssertTrue(session.controlsEnabled)
        await session.disconnect()
        XCTAssertEqual(session.phase, .disconnected)
        XCTAssertFalse(session.controlsEnabled)
        await client.resetOperations()
        await session.perform(.activate)
        XCTAssertEqual(await client.operations(), [])
    }

    func testConnectionLossLeavesNoUsableStaleClient() async {
        let client = FakeVoiceOverHostClient()
        let session = MacRemoteControlSession(
            connectionFactory: FakeMacRemoteControlConnectionFactory(clients: [client])
        )
        await session.connect(profile: macProfile(), configuration: configuration())
        XCTAssertEqual(session.lastSpokenPhraseText, "Safari")
        await client.resetOperations()
        await client.finishUnavailable()
        await waitUntil {
            if case .failed = session.phase { return true }
            return false
        }
        XCTAssertEqual(session.phase, .failed("The FarRelay Host connection closed."))
        XCTAssertFalse(session.controlsEnabled)
        XCTAssertEqual(session.lastSpokenPhraseText, "Safari")
        await session.perform(.nextItem)
        XCTAssertEqual(await client.operations(), [])
        XCTAssertTrue(await client.isUnavailable())
    }

    func testReconnectCreatesACleanSessionAndDoesNotLeakProfiles() async {
        let first = FakeVoiceOverHostClient(
            state: VoiceOverState(lastSpokenPhrase: "Safari", voiceOverCursorText: "Search field", keyboardCursorText: nil)
        )
        let second = FakeVoiceOverHostClient(
            state: VoiceOverState(lastSpokenPhrase: "Mail", voiceOverCursorText: "Inbox", keyboardCursorText: "To")
        )
        let factory = FakeMacRemoteControlConnectionFactory(clients: [first, second])
        let session = MacRemoteControlSession(connectionFactory: factory)
        let firstProfile = macProfile(name: "Mac mini", address: "mini.example")
        let secondProfile = macProfile(name: "Studio", address: "studio.example")

        await session.connect(profile: firstProfile, configuration: configuration(host: "mini.example"))
        XCTAssertEqual(session.activeProfile?.id, firstProfile.id)
        XCTAssertEqual(session.lastSpokenPhraseText, "Safari")
        await session.disconnect()

        await session.connect(
            profile: secondProfile,
            configuration: configuration(host: "studio.example")
        )
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.activeProfile?.id, secondProfile.id)
        XCTAssertEqual(session.lastSpokenPhraseText, "Mail")
        XCTAssertEqual(session.voiceOverCursorText, "Inbox")
        XCTAssertEqual(await factory.hosts(), ["mini.example", "studio.example"])
        XCTAssertEqual(await factory.openCount(), 2)
        await first.resetOperations()
        await session.perform(.nextItem)
        XCTAssertEqual(await first.operations(), [])
        XCTAssertEqual(await second.operations().suffix(2), ["move.right", "voiceover.state"])
        await session.disconnect()
        XCTAssertEqual(session.phase, .disconnected)
    }

    func testLeavingSessionCleansUpConnection() async {
        let client = FakeVoiceOverHostClient()
        let factory = FakeMacRemoteControlConnectionFactory(clients: [client])
        let session = MacRemoteControlSession(connectionFactory: factory)
        await session.connect(profile: macProfile(), configuration: configuration())
        XCTAssertEqual(await factory.openCount(), 1)
        await session.disconnect()
        XCTAssertTrue(await client.isUnavailable())
        XCTAssertFalse(session.controlsEnabled)
        await client.resetOperations()
        await session.perform(.refreshState)
        XCTAssertEqual(await client.operations(), [])
    }

    private func macProfile(
        name: String = "Mac mini",
        address: String = "mac.example",
        port: Int = 22,
        username: String = "tester"
    ) -> HostProfile {
        HostProfile(
            displayName: name,
            address: address,
            port: port,
            username: username,
            platform: .macOS
        )
    }

    private func configuration(
        host: String = "mac.example",
        port: Int = 22,
        username: String = "tester"
    ) -> SSHSessionConfiguration {
        SSHSessionConfiguration(
            host: host,
            port: port,
            username: username,
            authentication: .password("password")
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MacRemoteControlSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private actor FakeMacRemoteControlConnectionFactory: MacRemoteControlConnectionFactory {
    private var clients: [FakeVoiceOverHostClient]
    private var index = 0
    private var recordedCommands: [String] = []
    private var recordedHosts: [String] = []
    private var recordedPorts: [Int] = []
    private var recordedUsernames: [String] = []
    private var opens = 0

    init(clients: [FakeVoiceOverHostClient]) {
        self.clients = clients
    }

    func openSession(
        configuration: SSHSessionConfiguration,
        hostCommand: String,
        handle: @escaping @Sendable (any HostClientProtocol) async throws -> Void
    ) async throws {
        opens += 1
        recordedCommands.append(hostCommand)
        recordedHosts.append(configuration.host)
        recordedPorts.append(configuration.port)
        recordedUsernames.append(configuration.username)
        let client = clients[min(index, clients.count - 1)]
        index += 1
        try await handle(client)
        await client.finishUnavailable()
    }

    func hostCommands() -> [String] { recordedCommands }
    func hosts() -> [String] { recordedHosts }
    func ports() -> [Int] { recordedPorts }
    func usernames() -> [String] { recordedUsernames }
    func openCount() -> Int { opens }
}

private actor FakeVoiceOverHostClient: HostClientProtocol {
    private var capabilitiesResult: HostCapabilities
    private var statusResult: VoiceOverStatus
    private var stateResult: VoiceOverState
    private var recorded: [String] = []
    private var moveError: HostClientError?
    private var stateError: HostClientError?
    private var failStateAfterMoves = false
    private var blockMoves = false
    private var moveGate: CheckedContinuation<Void, Never>?
    private var unavailable = false
    private var unavailableWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        capabilities: HostCapabilities = FakeVoiceOverHostClient.voiceOverCapabilities,
        status: VoiceOverStatus = FakeVoiceOverHostClient.usableStatus,
        state: VoiceOverState = VoiceOverState(
            lastSpokenPhrase: "Safari",
            voiceOverCursorText: "Search field",
            keyboardCursorText: nil
        )
    ) {
        capabilitiesResult = capabilities
        statusResult = status
        stateResult = state
    }

    static let voiceOverCapabilities = HostCapabilities(
        protocolVersion: 1,
        hostImplementation: "farrelay-host",
        hostVersion: "0.1.0",
        operations: [
            "host.info",
            "process.list",
            "process.info",
            "voiceover.status",
            "voiceover.move",
            "voiceover.press",
            "voiceover.state",
        ]
    )

    static let usableStatus = VoiceOverStatus(
        platformSupported: true,
        available: true,
        voiceOverRunning: true,
        appleScriptBridgeUsable: true,
        message: nil
    )

    func capabilities() async throws -> HostCapabilities {
        try ensureAvailable()
        recorded.append("capabilities")
        return capabilitiesResult
    }

    func hostInfo() async throws -> HostInfo {
        try ensureAvailable()
        throw HostClientError.hostError(code: "unexpected", message: "host.info should not be used by Remote Control")
    }

    func processes() async throws -> [HostProcessInfo] {
        try ensureAvailable()
        throw HostClientError.hostError(code: "unexpected", message: "process.list should not be used by Remote Control")
    }

    func processInfo(pid: UInt32) async throws -> HostProcessInfo {
        try ensureAvailable()
        throw HostClientError.hostError(code: "unexpected", message: "process.info should not be used by Remote Control")
    }

    func voiceOverStatus() async throws -> VoiceOverStatus {
        try ensureAvailable()
        recorded.append("voiceover.status")
        return statusResult
    }

    func voiceOverMove(_ direction: VoiceOverMoveDirection) async throws -> VoiceOverMoveResult {
        try ensureAvailable()
        recorded.append("move.\(direction.rawValue)")
        if blockMoves {
            await withCheckedContinuation { continuation in
                moveGate = continuation
            }
        }
        if let moveError { throw moveError }
        return VoiceOverMoveResult(moved: true)
    }

    func voiceOverPress() async throws -> VoiceOverPressResult {
        try ensureAvailable()
        recorded.append("voiceover.press")
        return VoiceOverPressResult(pressed: true)
    }

    func voiceOverState() async throws -> VoiceOverState {
        try ensureAvailable()
        recorded.append("voiceover.state")
        if failStateAfterMoves && recorded.contains(where: { $0.hasPrefix("move.") }) {
            throw HostClientError.hostError(code: "internal_error", message: "state probe failed")
        }
        if let stateError { throw stateError }
        return stateResult
    }

    func waitUntilUnavailable() async {
        if unavailable { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if unavailable {
                    continuation.resume()
                } else {
                    unavailableWaiters.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.resumeUnavailableWaiters() }
        }
    }

    func finishUnavailable() {
        unavailable = true
        resumeUnavailableWaiters()
        if let moveGate {
            self.moveGate = nil
            moveGate.resume()
        }
    }

    private func resumeUnavailableWaiters() {
        let waiters = unavailableWaiters
        unavailableWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func resetOperations() { recorded.removeAll() }
    func operations() -> [String] { recorded }
    func moveCount() -> Int { recorded.filter { $0.hasPrefix("move.") }.count }
    func isUnavailable() -> Bool { unavailable }
    func setMoveError(_ error: HostClientError?) { moveError = error }
    func setStateError(_ error: HostClientError?) { stateError = error }
    func setFailStateAfterMoves(_ value: Bool) { failStateAfterMoves = value }
    func blockNextMove() { blockMoves = true }

    func unblockMoves() {
        blockMoves = false
        let gate = moveGate
        moveGate = nil
        gate?.resume()
    }

    private func ensureAvailable() throws {
        if unavailable { throw HostClientError.connectionClosed }
    }
}

private final class TestRemoteControlCredentialStore: CredentialStore {
    private var values: [String: String] = [:]

    func string(for account: String) throws -> String? { values[account] }
    func store(_ value: String, for account: String) throws { values[account] = value }
    func removeValue(for account: String) throws { values.removeValue(for: account) }
}
