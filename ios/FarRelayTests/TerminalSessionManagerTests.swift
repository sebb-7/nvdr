import Foundation
import XCTest
@testable import FarRelay

@MainActor
final class TerminalSessionManagerTests: XCTestCase {
    func testManagerBeginsWithZeroSessions() {
        let manager = TerminalSessionManager(connectionFactory: UniqueFakeTerminalFactory())
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.hostGroups(using: []).isEmpty)
    }

    func testOpeningOneTerminalCreatesAStableSessionID() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        let session = try await opened(manager, g14, settings: settings)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(session.id, manager.sessions[0].id)
        XCTAssertEqual(session.hostProfileID, g14.id)
        XCTAssertEqual(session.title, "Terminal 1")
        XCTAssertEqual(session.hostProfileID, session.profileSnapshot.id)
    }

    func testTwoTerminalsOnTheSameHostHaveDifferentIDsAndCoexist() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        let first = try await opened(manager, g14, settings: settings)
        await waitUntil { first.host.state == .connected }
        let second = try await opened(manager, g14, settings: settings)
        await waitUntil { second.host.state == .connected }

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(first.hostProfileID, second.hostProfileID)
        XCTAssertEqual(first.title, "Terminal 1")
        XCTAssertEqual(second.title, "Terminal 2")
        XCTAssertEqual(first.host.state, .connected)
        XCTAssertEqual(second.host.state, .connected)
        XCTAssertFalse(first.host.presentation === second.host.presentation)
    }

    func testTerminalsOnTwoHostsCoexistAndGroupByProfileIDNotName() async throws {
        let (manager, settings, profiles) = try makeEnvironment(hosts: ["G14", "Mac mini"])
        let g14 = profiles[0]
        var mac = profiles[1]
        mac.displayName = "G14"
        XCTAssertTrue(settings.saveProfile(mac, credentials: HostProfileCredentials(password: "pw")))

        let first = try await opened(manager, g14, settings: settings)
        let second = try await opened(manager, mac, settings: settings)
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertNotEqual(first.hostProfileID, second.hostProfileID)

        let groups = manager.hostGroups(using: settings.hostProfiles)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].hostProfileID, mac.id)
        XCTAssertEqual(groups[1].hostProfileID, g14.id)
        XCTAssertEqual(groups.map(\.sessions.count), [1, 1])
    }

    func testTwoSessionsForOneHostProduceOneGroup() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        _ = try await opened(manager, g14, settings: settings)
        _ = try await opened(manager, g14, settings: settings)
        let groups = manager.hostGroups(using: settings.hostProfiles)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sessions.count, 2)
        XCTAssertEqual(groups[0].sessions.map(\.title), ["Terminal 2", "Terminal 1"])
        XCTAssertEqual(groups[0].accessibilitySummary(isExpanded: true), "G14, 2 terminals, expanded")
        XCTAssertEqual(groups[0].accessibilitySummary(isExpanded: false), "G14, 2 terminals, collapsed")
    }

    func testClosingOneOfTwoSessionsLeavesTheOther() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        let first = try await opened(manager, g14, settings: settings)
        let second = try await opened(manager, g14, settings: settings)
        await waitUntil { first.host.state == .connected }
        let secondPresentation = second.host.presentation
        await manager.close(first.id)
        XCTAssertEqual(manager.sessions.map(\.id), [second.id])
        XCTAssertTrue(manager.session(id: first.id) == nil)
        XCTAssertTrue(second.host.presentation === secondPresentation)
        XCTAssertEqual(manager.hostGroups(using: settings.hostProfiles).count, 1)
    }

    func testClosingTheLastSessionRemovesTheHostGroup() async throws {
        let (manager, settings, profiles) = try makeEnvironment(hosts: ["G14", "Mac mini"])
        let g14 = try await opened(manager, profiles[0], settings: settings)
        let mac = try await opened(manager, profiles[1], settings: settings)
        await manager.close(g14.id)
        XCTAssertEqual(manager.hostGroups(using: settings.hostProfiles).map(\.hostProfileID), [profiles[1].id])
        XCTAssertEqual(settings.hostProfiles.map(\.id), [profiles[0].id, profiles[1].id])
        await manager.close(mac.id)
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.hostGroups(using: settings.hostProfiles).isEmpty)
        XCTAssertEqual(settings.hostProfiles.count, 2)
    }

    func testCloseIsIdempotentAndDoesNotAffectAnotherHost() async throws {
        let (manager, settings, profiles) = try makeEnvironment(hosts: ["G14", "Mac mini"])
        let g14 = try await opened(manager, profiles[0], settings: settings)
        let mac = try await opened(manager, profiles[1], settings: settings)
        await waitUntil { mac.host.state == .connected }
        await manager.close(g14.id)
        await manager.close(g14.id)
        await manager.close(UUID())
        XCTAssertEqual(manager.sessions.map(\.id), [mac.id])
        XCTAssertEqual(mac.host.state, .connected)
    }

    func testSessionsRemainUntilExplicitClose() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        let session = try await opened(manager, g14, settings: settings)
        manager.setTerminalInteractionActive(false)
        manager.present(nil)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.session(id: session.id)?.id, session.id)
        await manager.close(session.id)
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testTitleIsStableAndIDSurvivesDisplayNameChanges() async throws {
        let (manager, settings, original) = try makeManager(hosts: ["G14"])
        let session = try await opened(manager, original, settings: settings)
        let id = session.id
        let title = session.title
        var renamed = original
        renamed.displayName = "Gaming Laptop"
        XCTAssertTrue(settings.saveProfile(renamed, credentials: HostProfileCredentials(password: "pw")))
        XCTAssertEqual(manager.session(id: id)?.title, title)
        XCTAssertEqual(manager.session(id: id)?.id, id)
        XCTAssertEqual(manager.hostGroups(using: settings.hostProfiles)[0].displayName, "Gaming Laptop")
    }

    func testDeletedProfileKeepsExistingSessionButCannotOpenAnother() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        let session = try await opened(manager, g14, settings: settings)
        XCTAssertTrue(settings.deleteProfile(g14))
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(session.displayName(from: settings.hostProfiles), "G14")
        let groups = manager.hostGroups(using: settings.hostProfiles)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].displayName, "G14")
        XCTAssertFalse(groups[0].canOpenNewTerminal)
        let opened = await manager.openTerminal(for: g14, settings: settings)
        XCTAssertNil(opened)
        XCTAssertEqual(manager.sessions.count, 1)
    }

    func testFailedSessionRemainsUntilExplicitlyClosed() async throws {
        let factory = UniqueFakeTerminalFactory(failure: .connect)
        let (manager, settings, g14) = try makeManager(hosts: ["G14"], factory: factory)
        let session = try await opened(manager, g14, settings: settings)
        await waitUntil {
            if case .failed = session.host.state { return true }
            return false
        }
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertTrue(session.host.state.statusLabel.hasPrefix("Failed:"))
        await manager.close(session.id)
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testRemoteIntentDoesNotTargetAHiddenTerminal() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        let session = try await opened(manager, g14, settings: settings)
        await waitUntil { session.host.state == .connected }
        let target = TerminalRemoteIntentTarget(manager: manager)

        let hidden = await target.perform(.terminalInterrupt)
        XCTAssertEqual(hidden, .unavailable("No SSH terminal is currently active."))

        manager.present(session.id)
        manager.setTerminalInteractionActive(false)
        let inactiveTab = await target.perform(.terminalInterrupt)
        XCTAssertEqual(inactiveTab, .unavailable("No SSH terminal is currently active."))

        manager.setTerminalInteractionActive(true)
        let active = await target.perform(.terminalInterrupt)
        XCTAssertEqual(active, .performed)

        manager.present(nil)
        let cleared = await target.perform(.terminalInterrupt)
        XCTAssertEqual(cleared, .unavailable("No SSH terminal is currently active."))
    }

    func testNewestUnpinnedSessionSortsFirst() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        let first = try await opened(manager, g14, settings: settings)
        let second = try await opened(manager, g14, settings: settings)
        let third = try await opened(manager, g14, settings: settings)
        XCTAssertEqual(
            manager.hostGroups(using: settings.hostProfiles)[0].sessions.map(\.id),
            [third.id, second.id, first.id]
        )
    }

    func testPinnedSessionsSortAboveUnpinnedAndKeepStablePinOrder() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        let first = try await opened(manager, g14, settings: settings)
        let second = try await opened(manager, g14, settings: settings)
        let third = try await opened(manager, g14, settings: settings)
        manager.pin(second.id)
        XCTAssertEqual(
            manager.hostGroups(using: settings.hostProfiles)[0].sessions.map(\.id),
            [second.id, third.id, first.id]
        )
        manager.pin(first.id)
        XCTAssertEqual(
            manager.hostGroups(using: settings.hostProfiles)[0].sessions.map(\.id),
            [first.id, second.id, third.id]
        )
        XCTAssertEqual(manager.session(id: first.id)?.id, first.id)
        XCTAssertEqual(manager.session(id: second.id)?.id, second.id)
    }

    func testPinAndUnpinDoNotChangeSessionIdentityOrReconnect() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        let session = try await opened(manager, g14, settings: settings)
        await waitUntil { session.host.state == .connected }
        let host = session.host
        manager.pin(session.id)
        XCTAssertTrue(session.isPinned)
        XCTAssertTrue(session.host === host)
        XCTAssertEqual(session.host.state, .connected)
        manager.unpin(session.id)
        XCTAssertFalse(session.isPinned)
        XCTAssertTrue(session.host === host)
        XCTAssertEqual(session.host.state, .connected)
        XCTAssertEqual(manager.session(id: session.id)?.title, "Terminal 1")
    }

    func testMoveUpAndDownStayWithinPinnedOrUnpinnedCategory() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        let first = try await opened(manager, g14, settings: settings)
        let second = try await opened(manager, g14, settings: settings)
        let third = try await opened(manager, g14, settings: settings)
        manager.pin(first.id)
        manager.pin(second.id)
        manager.moveDown(second.id)
        XCTAssertEqual(
            manager.hostGroups(using: settings.hostProfiles)[0].sessions.map(\.id),
            [first.id, second.id, third.id]
        )
        manager.moveUp(second.id)
        XCTAssertEqual(
            manager.hostGroups(using: settings.hostProfiles)[0].sessions.map(\.id),
            [second.id, first.id, third.id]
        )
        manager.moveUp(third.id)
        XCTAssertEqual(
            manager.hostGroups(using: settings.hostProfiles)[0].sessions.map(\.id),
            [second.id, first.id, third.id]
        )
        XCTAssertFalse(manager.capabilities(for: third.id).canMoveUp)
        XCTAssertFalse(manager.capabilities(for: third.id).canMoveDown)
    }

    func testMoveCannotCrossHostProfiles() async throws {
        let (manager, settings, profiles) = try makeEnvironment(hosts: ["G14", "Mac mini"])
        let g14 = try await opened(manager, profiles[0], settings: settings)
        let mac = try await opened(manager, profiles[1], settings: settings)
        manager.moveUp(mac.id)
        manager.moveDown(mac.id)
        manager.moveUp(g14.id)
        let groups = manager.hostGroups(using: settings.hostProfiles)
        XCTAssertEqual(groups[0].hostProfileID, profiles[1].id)
        XCTAssertEqual(groups[0].sessions.map(\.id), [mac.id])
        XCTAssertEqual(groups[1].hostProfileID, profiles[0].id)
        XCTAssertEqual(groups[1].sessions.map(\.id), [g14.id])
    }

    func testPassiveOutputAndConnectionChangesDoNotReorder() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        let first = try await opened(manager, g14, settings: settings)
        let second = try await opened(manager, g14, settings: settings)
        let before = manager.hostGroups(using: settings.hostProfiles)[0].sessions.map(\.id)
        XCTAssertEqual(before, [second.id, first.id])
        manager.setTerminalInteractionActive(false)
        manager.noteIncomingOutput(from: first.id)
        await waitUntil { first.host.state == .connected && second.host.state == .connected }
        XCTAssertEqual(
            manager.hostGroups(using: settings.hostProfiles)[0].sessions.map(\.id),
            before
        )
        XCTAssertTrue(first.hasUnseenOutput)
        XCTAssertFalse(second.hasUnseenOutput)
        XCTAssertEqual(
            manager.hostGroups(using: settings.hostProfiles)[0].accessibilitySummary(isExpanded: false),
            "G14, 2 terminals, 1 with new output, collapsed"
        )
    }

    func testNewTerminalPromotesHostGroupAndBackgroundOutputDoesNot() async throws {
        let (manager, settings, profiles) = try makeEnvironment(hosts: ["G14", "Mac mini"])
        let g14First = try await opened(manager, profiles[0], settings: settings)
        _ = try await opened(manager, profiles[1], settings: settings)
        XCTAssertEqual(manager.hostGroups(using: settings.hostProfiles).map(\.hostProfileID), [profiles[1].id, profiles[0].id])
        manager.setTerminalInteractionActive(false)
        manager.noteIncomingOutput(from: g14First.id)
        XCTAssertEqual(manager.hostGroups(using: settings.hostProfiles).map(\.hostProfileID), [profiles[1].id, profiles[0].id])
        _ = try await opened(manager, profiles[0], settings: settings)
        XCTAssertEqual(manager.hostGroups(using: settings.hostProfiles).map(\.hostProfileID), [profiles[0].id, profiles[1].id])
    }

    func testRenameChangesTitleWithoutChangingIdentityHostOrTranscript() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        let session = try await opened(manager, g14, settings: settings)
        await waitUntil { session.host.state == .connected }
        let presentation = session.host.presentation
        let transcript = presentation.conversationEntries.map(\.text)
        let id = session.id
        XCTAssertTrue(manager.rename(id, to: "  Claude  "))
        XCTAssertEqual(session.title, "Claude")
        XCTAssertEqual(session.id, id)
        XCTAssertTrue(session.host.presentation === presentation)
        XCTAssertEqual(session.hostProfileID, g14.id)
        XCTAssertEqual(presentation.conversationEntries.map(\.text), transcript)
        XCTAssertFalse(manager.rename(id, to: "   "))
        XCTAssertEqual(session.title, "Claude")
        XCTAssertTrue(manager.rename(id, to: "Codex"))
        let other = try await opened(manager, g14, settings: settings)
        XCTAssertTrue(manager.rename(other.id, to: "Codex"))
        XCTAssertEqual(session.title, "Codex")
        XCTAssertEqual(other.title, "Codex")
        XCTAssertNotEqual(session.id, other.id)
    }

    func testRetryKeepsFailedSessionAndCreatesReplacementWithSameTitle() async throws {
        let factory = UniqueFakeTerminalFactory(failure: .connect)
        let (manager, settings, g14) = try makeManager(hosts: ["G14"], factory: factory)
        let failed = try await opened(manager, g14, settings: settings)
        await waitUntil {
            if case .failed = failed.host.state { return true }
            return false
        }
        XCTAssertTrue(manager.rename(failed.id, to: "PowerShell"))
        let originalHost = failed.host
        let retried = await manager.retry(failed.id, settings: settings)
        let replacement = try XCTUnwrap(retried)
        XCTAssertNotEqual(replacement.id, failed.id)
        XCTAssertEqual(replacement.title, "PowerShell")
        XCTAssertEqual(failed.title, "PowerShell")
        XCTAssertTrue(failed.host === originalHost)
        if case .failed = failed.host.state {
        } else {
            XCTFail("Failed session must remain inspectable")
        }
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertTrue(manager.capabilities(for: failed.id).canRetry)
    }

    func testNewOutputMarkerClearsOnOpenAndIsIndependentPerSession() async throws {
        let (manager, settings, profiles) = try makeEnvironment(hosts: ["G14", "Mac mini"])
        let g14 = try await opened(manager, profiles[0], settings: settings)
        let mac = try await opened(manager, profiles[1], settings: settings)
        manager.present(g14.id)
        manager.setTerminalInteractionActive(true)
        manager.noteIncomingOutput(from: g14.id)
        XCTAssertFalse(g14.hasUnseenOutput)
        manager.setTerminalInteractionActive(false)
        manager.noteIncomingOutput(from: g14.id)
        XCTAssertTrue(g14.hasUnseenOutput)
        manager.noteIncomingOutput(from: mac.id)
        XCTAssertTrue(mac.hasUnseenOutput)
        manager.present(g14.id)
        XCTAssertFalse(g14.hasUnseenOutput)
        XCTAssertTrue(mac.hasUnseenOutput)
        await manager.close(mac.id)
        XCTAssertNil(manager.session(id: mac.id))
        XCTAssertEqual(
            manager.hostGroups(using: settings.hostProfiles)[0].accessibilitySummary(isExpanded: true),
            "G14, 1 terminal, expanded"
        )
    }

    func testIncomingPresentationCallbackMarksBackgroundOutput() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        let session = try await opened(manager, g14, settings: settings)
        manager.setTerminalInteractionActive(false)
        XCTAssertNotNil(session.host.presentation.onIncomingConversationContent)
        session.host.presentation.onIncomingConversationContent?()
        XCTAssertTrue(session.hasUnseenOutput)
    }

    func testConnectionFailurePublishesLifecycleEventWithoutPresentationState() async throws {
        let factory = UniqueFakeTerminalFactory(failure: .connect)
        let (manager, settings, g14) = try makeManager(hosts: ["G14"], factory: factory)
        let session = try await opened(manager, g14, settings: settings)
        await waitUntil {
            if case .failed = manager.lastLifecycleEvent?.currentState {
                return true
            }
            return false
        }
        XCTAssertEqual(manager.lastLifecycleEvent?.sessionID, session.id)
        if case .failed = manager.lastLifecycleEvent?.currentState {
        } else {
            XCTFail("Expected a failed lifecycle event")
        }
        if case .failed = session.host.state {
        } else {
            XCTFail("Expected failed session")
        }
        XCTAssertTrue(manager.capabilities(for: session.id).canRetry)
        XCTAssertTrue(manager.accessibilityActions(for: session.id).contains(.retry))
        XCTAssertFalse(manager.accessibilityActions(for: session.id).contains(.moveUp))
    }

    func testConnectedSessionActionsOmitRetryAndIncludePin() async throws {
        let (manager, settings, g14) = try makeManager(hosts: ["G14"])
        let session = try await opened(manager, g14, settings: settings)
        await waitUntil { session.host.state == .connected }
        XCTAssertEqual(
            manager.accessibilityActions(for: session.id),
            [.pin, .rename, .close]
        )
        manager.pin(session.id)
        XCTAssertEqual(
            manager.accessibilityActions(for: session.id),
            [.unpin, .rename, .close]
        )
        XCTAssertEqual(session.accessibilityLabel, "Terminal 1, connected, pinned")
        manager.setTerminalInteractionActive(false)
        manager.noteIncomingOutput(from: session.id)
        XCTAssertEqual(session.accessibilityLabel, "Terminal 1, connected, pinned, new output")
    }

    private func makeManager(
        hosts: [String],
        factory: UniqueFakeTerminalFactory = UniqueFakeTerminalFactory()
    ) throws -> (TerminalSessionManager, AppSettings, HostProfile) {
        let environment = try makeEnvironment(hosts: hosts, factory: factory)
        return (environment.manager, environment.settings, environment.profiles[0])
    }

    private func makeEnvironment(
        hosts: [String],
        factory: UniqueFakeTerminalFactory = UniqueFakeTerminalFactory()
    ) throws -> (manager: TerminalSessionManager, settings: AppSettings, profiles: [HostProfile]) {
        let suiteName = "TerminalSessionManagerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = ManagerTestCredentialStore()
        let settings = AppSettings(defaults: defaults, credentialStore: credentials)
        var profiles: [HostProfile] = []
        for name in hosts {
            let profile = HostProfile(
                displayName: name,
                address: "\(name.replacing(" ", with: "-")).example",
                username: "user"
            )
            XCTAssertTrue(settings.saveProfile(profile, credentials: HostProfileCredentials(password: "pw")))
            profiles.append(profile)
        }
        return (TerminalSessionManager(connectionFactory: factory), settings, profiles)
    }

    private func opened(
        _ manager: TerminalSessionManager,
        _ profile: HostProfile,
        settings: AppSettings
    ) async throws -> TerminalSession {
        let session = await manager.openTerminal(for: profile, settings: settings)
        return try XCTUnwrap(session)
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

private final class UniqueFakeTerminalFactory: SSHTerminalHostConnectionFactory, @unchecked Sendable {
    private let failure: FakeManagerTerminalConnection.Failure?

    init(failure: FakeManagerTerminalConnection.Failure? = nil) {
        self.failure = failure
    }

    func makeConnection(configuration: SSHSessionConfiguration) -> any SSHTerminalHostConnection {
        FakeManagerTerminalConnection(failure: failure)
    }
}

private actor FakeManagerTerminalConnection: SSHTerminalHostConnection {
    enum Failure: Equatable, Sendable {
        case connect
    }

    private let failure: Failure?
    private let transport = FakeManagerTerminalTransport()

    init(failure: Failure? = nil) {
        self.failure = failure
    }

    func connect() async throws {
        if failure == .connect { throw FakeManagerTerminalError.connection }
    }

    func withTerminalPTY(
        configuration: SSHPTYConfiguration,
        operation: @escaping @Sendable (any SSHPTYTransporting) async throws -> Void
    ) async throws {
        try await operation(transport)
    }

    func close() async throws {
        await transport.releaseReadLoop()
    }
}

private actor FakeManagerTerminalTransport: SSHPTYTransporting {
    private var continuation: CheckedContinuation<Void, Never>?

    func consumeEvents(
        _ handler: @escaping @Sendable (SSHPTYEvent) async throws -> Void
    ) async throws {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        try Task.checkCancellation()
    }

    func write(_ data: Data) async throws {}

    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}

    func releaseReadLoop() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private enum FakeManagerTerminalError: LocalizedError, Sendable {
    case connection
    var errorDescription: String? { "Fake connection failure." }
}

private final class ManagerTestCredentialStore: CredentialStore {
    private var values: [String: String] = [:]
    func string(for account: String) throws -> String? { values[account] }
    func store(_ value: String, for account: String) throws { values[account] = value }
    func removeValue(for account: String) throws { values.removeValue(forKey: account) }
}
