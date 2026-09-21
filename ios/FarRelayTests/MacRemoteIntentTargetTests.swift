import XCTest
@testable import FarRelay

@MainActor
final class MacRemoteIntentTargetTests: XCTestCase {
    func testTargetReusesHostProfileIdentityAndReportsRawKeyboardCapabilities() {
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
        XCTAssertEqual(
            target.target.capabilities,
            [.accessibilityNavigation, .applicationSwitching, .rawKeyInput, .rawChordInput, .macRemoteControl]
        )
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
        XCTAssertTrue(controller.keyTransitions.isEmpty)
    }

    func testMacRawKeyAndCommandChordUseHIDTransitions() async throws {
        let controller = FakeMacRemoteIntentController(state: .ready)
        let mac = MacRemoteIntentTarget(controller: controller)
        let router = RemoteIntentRouter()
        router.register(mac)
        XCTAssertTrue(router.setActiveTarget(id: MacRemoteIntentTarget.defaultID))

        XCTAssertEqual(await router.route(.sendKey(.tab)), .performed)
        let v = try XCTUnwrap(RemoteKey.letter("v"))
        XCTAssertEqual(
            await router.route(.sendChord(.init(modifiers: [.commandOrWindows], key: v))),
            .performed
        )

        XCTAssertEqual(
            controller.keyTransitions,
            [
                .init(0x2B, true), .init(0x2B, false),
                .init(0xE3, true), .init(0x19, true),
                .init(0x19, false), .init(0xE3, false)
            ]
        )
    }

    func testMacRejectsWindowsVirtualKeyWithoutTouchingController() async {
        let controller = FakeMacRemoteIntentController(state: .ready)
        let mac = MacRemoteIntentTarget(controller: controller)
        let router = RemoteIntentRouter()
        router.register(mac)
        XCTAssertTrue(router.setActiveTarget(id: MacRemoteIntentTarget.defaultID))

        let key = RemoteKey.windowsVirtualKey(0x56)
        let result = await router.route(.sendKey(key))

        XCTAssertEqual(result, .unsupported)
        XCTAssertTrue(controller.keyTransitions.isEmpty)
        XCTAssertEqual(
            router.lastDecision,
            .dispatched(targetID: MacRemoteIntentTarget.defaultID, intent: .sendKey(key))
        )
    }

    func testMacHeldKeyOwnershipResetsAcrossControlGeneration() async throws {
        let controller = FakeMacRemoteIntentController(state: .ready, generation: 1)
        let mac = MacRemoteIntentTarget(controller: controller)
        let key = try XCTUnwrap(RemoteKey.hidUsage(0x19))

        XCTAssertEqual(await mac.perform(.sendKeyTransition(key, pressed: true)), .performed)
        controller.remoteIntentGeneration = 2
        XCTAssertEqual(await mac.perform(.sendKeyTransition(key, pressed: true)), .performed)
        XCTAssertEqual(await mac.perform(.sendKeyTransition(key, pressed: false)), .performed)

        XCTAssertEqual(
            controller.keyTransitions,
            [
                .init(0x19, true),
                .init(0x19, true),
                .init(0x19, false)
            ]
        )
    }

    func testMacStaleReleaseAfterGenerationChangeDoesNotTouchNewLease() async throws {
        let controller = FakeMacRemoteIntentController(state: .ready, generation: 1)
        let mac = MacRemoteIntentTarget(controller: controller)
        let key = try XCTUnwrap(RemoteKey.hidUsage(0x19))

        _ = await mac.perform(.sendKeyTransition(key, pressed: true))
        controller.remoteIntentGeneration = 2
        _ = await mac.perform(.sendKeyTransition(key, pressed: false))

        XCTAssertEqual(controller.keyTransitions, [.init(0x19, true)])
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

        XCTAssertEqual(await windowsRouter.route(intent), .performed)
        XCTAssertEqual(await macRouter.route(intent), .performed)
        XCTAssertEqual(windowsSink.transitions, ["13 down", "13 up"])
        XCTAssertEqual(macController.actions, [.activate])
    }
}

private struct MacKeyTransition: Equatable {
    let usage: UInt16
    let pressed: Bool

    init(_ usage: UInt16, _ pressed: Bool) {
        self.usage = usage
        self.pressed = pressed
    }
}

@MainActor
private final class FakeMacRemoteIntentController: MacRemoteIntentControlling {
    let activeProfile: HostProfile?
    let remoteIntentConnectionState: HostTarget.ConnectionState
    var remoteIntentGeneration: UInt64?
    var result: RemoteIntentResult
    private(set) var actions: [MacRemoteAction] = []
    private(set) var keyTransitions: [MacKeyTransition] = []

    init(
        profile: HostProfile? = nil,
        state: HostTarget.ConnectionState,
        generation: UInt64? = 1,
        result: RemoteIntentResult = .performed
    ) {
        activeProfile = profile
        remoteIntentConnectionState = state
        remoteIntentGeneration = generation
        self.result = result
    }

    func performMacRemoteAction(_ action: MacRemoteAction) async -> RemoteIntentResult {
        actions.append(action)
        return result
    }

    func performMacRemoteKeyTransition(
        _ key: MacRemoteKey,
        pressed: Bool
    ) async -> RemoteIntentResult {
        keyTransitions.append(.init(key.usage, pressed))
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
