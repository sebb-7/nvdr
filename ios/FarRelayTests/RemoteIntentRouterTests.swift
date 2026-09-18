import XCTest
@testable import FarRelay

@MainActor
final class RemoteIntentRouterTests: XCTestCase {
    func testRoutingWithoutAnActiveTargetIsUnavailable() async {
        let router = RemoteIntentRouter()

        let result = await router.route(.nextItem)

        XCTAssertEqual(result, .unavailable("No remote target is active."))
        XCTAssertEqual(router.lastDecision, .noActiveTarget(intent: .nextItem))
    }

    func testExplicitSelectionRoutesOnlyToSelectedTargetAndExposesCapabilities() async {
        let router = RemoteIntentRouter()
        let first = FakeRemoteIntentTarget(
            id: RemoteTargetID("first"),
            capabilities: [.genericNavigation]
        )
        let second = FakeRemoteIntentTarget(
            id: RemoteTargetID("second"),
            capabilities: [.genericNavigation, .rawKeyInput]
        )
        router.register(first)
        router.register(second)

        XCTAssertNil(router.activeTargetID)
        XCTAssertTrue(router.setActiveTarget(id: second.remoteTargetID))
        XCTAssertEqual(router.activeTargetID, second.remoteTargetID)
        XCTAssertEqual(router.activeTargetName, "second")
        XCTAssertEqual(router.activeCapabilities, [.genericNavigation, .rawKeyInput])
        XCTAssertEqual(router.capabilities(for: first.remoteTargetID), [.genericNavigation])
        XCTAssertEqual(router.target(for: second.remoteTargetID)?.kind, .sshTerminal)

        let result = await router.route(.nextItem)

        XCTAssertEqual(result, .performed)
        XCTAssertEqual(router.lastDecision, .dispatched(targetID: second.remoteTargetID, intent: .nextItem))
        XCTAssertTrue(first.performedIntents.isEmpty)
        XCTAssertEqual(second.performedIntents, [.nextItem])
    }

    func testSwitchingActiveTargetChangesOnlySubsequentRouting() async {
        let router = RemoteIntentRouter()
        let first = FakeRemoteIntentTarget(id: RemoteTargetID("first"), capabilities: [.genericNavigation])
        let second = FakeRemoteIntentTarget(id: RemoteTargetID("second"), capabilities: [.genericNavigation])
        router.register(first)
        router.register(second)

        XCTAssertTrue(router.setActiveTarget(id: first.remoteTargetID))
        _ = await router.route(.activate)
        XCTAssertTrue(router.setActiveTarget(id: second.remoteTargetID))
        _ = await router.route(.cancel)

        XCTAssertEqual(first.performedIntents, [.activate])
        XCTAssertEqual(second.performedIntents, [.cancel])
    }

    func testUnsupportedAndUnavailableResultsRemainDeterministic() async {
        let router = RemoteIntentRouter()
        let target = FakeRemoteIntentTarget(
            id: RemoteTargetID("limited"),
            capabilities: [.genericNavigation],
            result: .unavailable("Target is disconnected.")
        )
        router.register(target)
        XCTAssertTrue(router.setActiveTarget(id: target.remoteTargetID))

        let unsupported = await router.route(.nextApplication)
        let unavailable = await router.route(.nextItem)

        XCTAssertEqual(unsupported, .unsupported)
        XCTAssertEqual(
            router.lastDecision,
            .dispatched(targetID: target.remoteTargetID, intent: .nextItem)
        )
        XCTAssertEqual(unavailable, .unavailable("Target is disconnected."))
        XCTAssertEqual(target.performedIntents, [.nextItem])
    }

    func testRemovingActiveTargetClearsSelectionAndNeverFallsBack() async {
        let router = RemoteIntentRouter()
        let active = FakeRemoteIntentTarget(id: RemoteTargetID("active"), capabilities: [.genericNavigation])
        let other = FakeRemoteIntentTarget(id: RemoteTargetID("other"), capabilities: [.genericNavigation])
        router.register(active)
        router.register(other)
        XCTAssertTrue(router.setActiveTarget(id: active.remoteTargetID))

        router.removeTarget(id: active.remoteTargetID)
        let result = await router.route(.nextItem)

        XCTAssertNil(router.activeTargetID)
        XCTAssertEqual(result, .unavailable("No remote target is active."))
        XCTAssertEqual(router.lastDecision, .noActiveTarget(intent: .nextItem))
        XCTAssertTrue(other.performedIntents.isEmpty)
    }

    func testRawKeyValidationRejectsInvalidValues() {
        XCTAssertNil(RemoteKey.function(0))
        XCTAssertNil(RemoteKey.function(25))
        XCTAssertNil(RemoteKey.letter("é"))
        XCTAssertNil(RemoteKey.letter("1"))
        XCTAssertNotNil(RemoteKey.function(12))
        XCTAssertNotNil(RemoteKey.letter("a"))
    }
}

@MainActor
private final class FakeRemoteIntentTarget: HostTargetExecutor {
    let remoteTargetID: RemoteTargetID
    let capabilities: Set<RemoteCapability>
    var result: RemoteIntentResult
    private(set) var performedIntents: [RemoteIntent] = []

    init(
        id: RemoteTargetID,
        capabilities: Set<RemoteCapability>,
        result: RemoteIntentResult = .performed
    ) {
        remoteTargetID = id
        self.capabilities = capabilities
        self.result = result
    }

    var target: HostTarget {
        HostTarget(
            id: remoteTargetID,
            displayName: remoteTargetID.rawValue,
            profileID: nil,
            sessionID: nil,
            platform: .other,
            kind: .sshTerminal,
            connectionState: .ready,
            capabilities: capabilities
        )
    }

    func perform(_ intent: RemoteIntent) async -> RemoteIntentResult {
        performedIntents.append(intent)
        return result
    }
}
