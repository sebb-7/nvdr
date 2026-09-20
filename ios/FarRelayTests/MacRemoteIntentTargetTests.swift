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
        XCTAssertEqual(target.target.capabilities, [.accessibilityNavigation, .applicationSwitching, .macRemoteControl])
    }

    func testSelectedMacTargetRoutesOnlyItsSemanticAction() async {
        let controller = FakeMacRemoteIntentController(state: .ready)
        let mac = MacRemoteIntentTarget(controller: controller)
        let router = RemoteIntentRouter()
        router.register(mac)
        XCTAssertTrue(router.setActiveTarget(id: MacRemoteIntentTarget.defaultID))

        let result = await router.route(.accessibilityNext)

        XCTAssertEqual(result, .performed)
        XCTAssertEqual(controller.actions, [.nextItem])
        XCTAssertEqual(
            router.lastDecision,
            .dispatched(targetID: MacRemoteIntentTarget.defaultID, intent: .accessibilityNext)
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

        let result = await router.route(.accessibilityActivate)

        XCTAssertEqual(result, .unavailable("Mac Remote control has not been granted."))
        XCTAssertEqual(controller.actions, [.activate])
        XCTAssertEqual(router.activeTargetID, MacRemoteIntentTarget.defaultID)
    }

    func testSameAccessibilityIntentHasTargetSpecificSafeImplementations() async {
        let intent: RemoteIntent = .accessibilityActivate
        let windowsSink = CrossTargetWindowsSink()
        let nvda = NVDARemoteIntentTarget(keySink: windowsSink)
        let macController = FakeMacRemoteIntentController(state: .ready)
        let mac = MacRemoteIntentTarget(controller: macController)
        let windowsRouter = RemoteIntentRouter()
        let macRouter = RemoteIntentRouter()
        windowsRouter.register(nvda)
        macRouter.register(mac)
        XCTAssertTrue(windowsRouter.setActiveTarget(id: NVDARemoteIntentTarget.defaultID))
        XCTAssertTrue(macRouter.setActiveTarget(id: MacRemoteIntentTarget.defaultID))

        let nvdaResult = await windowsRouter.route(intent)
        let macResult = await macRouter.route(intent)
        XCTAssertEqual(nvdaResult, .performed)
        XCTAssertEqual(macResult, .performed)
        XCTAssertEqual(windowsSink.transitions, ["13 down", "13 up"])
        XCTAssertEqual(macController.actions, [.activate])
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

@MainActor
private final class CrossTargetWindowsSink: RemoteWindowsKeySink {
    var isInputForwardingReady = true
    var activeProfileID: UUID?
    var inputSessionID: UUID? = UUID()
    var lastInputForwardingResult: InputForwardingResult? = .accepted
    private(set) var transitions: [String] = []

    func sendKey(vk: UInt16, pressed: Bool) {
        let state = pressed ? "down" : "up"
        transitions.append("\(vk) \(state)")
    }
}
