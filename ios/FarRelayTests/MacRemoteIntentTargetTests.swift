import XCTest
@testable import FarRelay

@MainActor
final class MacRemoteIntentTargetTests: XCTestCase {
    func testTargetReusesHostProfileIdentityAndReportsLeaseReadiness() {
        let profile = HostProfile(displayName: "Mac mini", platform: .macOS, macRemote: .init(isEnabled: true))
        let controller = FakeMacRemoteIntentController(profile: profile, state: .ready)
        let target = MacRemoteIntentTarget(controller: controller)

        XCTAssertEqual(target.target.id, MacRemoteIntentTarget.defaultID)
        XCTAssertEqual(target.target.displayName, "Mac mini")
        XCTAssertEqual(target.target.profileID, profile.id)
        XCTAssertNil(target.target.sessionID)
        XCTAssertEqual(target.target.platform, .macOS)
        XCTAssertEqual(target.target.kind, .macRemote)
        XCTAssertEqual(target.target.connectionState, .ready)
        XCTAssertEqual(target.target.capabilities, [.macRemoteControl])
    }

    func testSelectedMacTargetRoutesOnlyItsSemanticAction() async {
        let controller = FakeMacRemoteIntentController(state: .ready)
        let mac = MacRemoteIntentTarget(controller: controller)
        let router = RemoteIntentRouter()
        router.register(mac)
        XCTAssertTrue(router.setActiveTarget(id: MacRemoteIntentTarget.defaultID))

        let result = await router.route(.macRemote(.nextItem))

        XCTAssertEqual(result, .performed)
        XCTAssertEqual(controller.actions, [.nextItem])
        XCTAssertEqual(
            router.lastDecision,
            .dispatched(targetID: MacRemoteIntentTarget.defaultID, intent: .macRemote(.nextItem))
        )
    }

    func testMacExecutorRejectsOtherCapabilitiesWithoutTouchingController() async {
        let controller = FakeMacRemoteIntentController(state: .ready)
        let mac = MacRemoteIntentTarget(controller: controller)
        let router = RemoteIntentRouter()
        router.register(mac)
        XCTAssertTrue(router.setActiveTarget(id: MacRemoteIntentTarget.defaultID))

        let result = await router.route(.sendKey(.tab))

        XCTAssertEqual(result, .unsupported)
        XCTAssertTrue(controller.actions.isEmpty)
        XCTAssertEqual(
            router.lastDecision,
            .unsupported(
                targetID: MacRemoteIntentTarget.defaultID,
                intent: .sendKey(.tab),
                capability: .rawKeyInput
            )
        )
    }

    func testLeaseBoundaryRemainsUnavailableAndDoesNotFallback() async {
        let controller = FakeMacRemoteIntentController(
            state: .unavailable("Mac Remote control has not been granted."),
            result: .unavailable("Mac Remote control has not been granted.")
        )
        let mac = MacRemoteIntentTarget(controller: controller)
        let router = RemoteIntentRouter()
        router.register(mac)
        XCTAssertTrue(router.setActiveTarget(id: MacRemoteIntentTarget.defaultID))

        let result = await router.route(.macRemote(.activate))

        XCTAssertEqual(result, .unavailable("Mac Remote control has not been granted."))
        XCTAssertEqual(controller.actions, [.activate])
        XCTAssertEqual(router.activeTargetID, MacRemoteIntentTarget.defaultID)
    }
}

@MainActor
private final class FakeMacRemoteIntentController: MacRemoteIntentControlling {
    let activeProfile: HostProfile?
    let remoteIntentConnectionState: HostTarget.ConnectionState
    var result: RemoteIntentResult
    private(set) var actions: [MacRemoteAction] = []

    init(
        profile: HostProfile? = nil,
        state: HostTarget.ConnectionState,
        result: RemoteIntentResult = .performed
    ) {
        activeProfile = profile
        remoteIntentConnectionState = state
        self.result = result
    }

    func performMacRemoteAction(_ action: MacRemoteAction) async -> RemoteIntentResult {
        actions.append(action)
        return result
    }
}
