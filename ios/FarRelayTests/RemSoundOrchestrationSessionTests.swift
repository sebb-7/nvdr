import XCTest
@testable import FarRelay

@MainActor
final class RemSoundOrchestrationSessionTests: XCTestCase {
    func testStartUsesSelectedComputerAddressSessionPortAndKeychainPassword() async {
        let descriptor = makeDescriptor(senderState: .starting)
        let host = FakeRemSoundHostOrchestrator(handshake: .init(
            capabilities: makeCapabilities(),
            descriptor: descriptor
        ))
        let receiver = FakeRemSoundReceiver()
        let session = RemSoundOrchestrationSession(receiver: receiver, host: host)
        let profile = makeProfile(address: "100.103.170.25")
        let credentials = HostProfileCredentials(password: "ssh-secret", remSoundPassword: "audio-secret")

        await session.start(
            profile: profile,
            credentials: credentials,
            targetLatencyMilliseconds: 90,
            autoTuneLatencyEnabled: true
        )

        XCTAssertEqual(host.handshakeCalls, 1)
        XCTAssertEqual(receiver.lastStart?.host, "100.103.170.25")
        XCTAssertEqual(receiver.lastStart?.port, 47_830)
        XCTAssertEqual(receiver.lastStart?.password, "audio-secret")
        XCTAssertEqual(receiver.lastStart?.targetLatencyMilliseconds, 90)
        XCTAssertEqual(receiver.lastStart?.autoTuneLatencyEnabled, true)
        XCTAssertEqual(session.senderState, .starting)
        XCTAssertEqual(session.state, .startingSender)

        receiver.snapshot.state = .buffering
        XCTAssertEqual(session.state, .buffering)
        receiver.snapshot.state = .playing
        XCTAssertEqual(session.state, .playing)
    }

    func testMissingRemSoundPasswordFailsBeforeReceiverStarts() async {
        let host = FakeRemSoundHostOrchestrator(handshake: .init(
            capabilities: makeCapabilities(),
            descriptor: makeDescriptor(senderState: .running)
        ))
        let receiver = FakeRemSoundReceiver()
        let session = RemSoundOrchestrationSession(receiver: receiver, host: host)

        await session.start(
            profile: makeProfile(),
            credentials: HostProfileCredentials(password: "ssh-secret")
        )

        XCTAssertNil(receiver.lastStart)
        guard case .failed(let message) = session.state else {
            return XCTFail("Expected password failure.")
        }
        XCTAssertTrue(message.contains("shared password"))
    }

    func testInvalidSessionContractFailsClosedWithoutRewritingReceiver() async {
        let host = FakeRemSoundHostOrchestrator(handshake: .init(
            capabilities: makeCapabilities(),
            descriptor: HostRemSoundSessionDescriptor(
                transport: "host_proxy",
                audioPort: 47_830,
                discoveryPort: 47_821,
                sampleRateHz: 48_000,
                channels: 2,
                codecs: ["opus", "pcm"],
                sharedPasswordRequired: true,
                peerSelectionRequired: true,
                senderState: .running,
                senderVersion: "RemSound test"
            )
        ))
        let receiver = FakeRemSoundReceiver()
        let session = RemSoundOrchestrationSession(receiver: receiver, host: host)

        await session.start(
            profile: makeProfile(),
            credentials: HostProfileCredentials(password: "ssh", remSoundPassword: "audio")
        )

        XCTAssertNil(receiver.lastStart)
        guard case .failed(let message) = session.state else {
            return XCTFail("Expected incompatible session failure.")
        }
        XCTAssertTrue(message.contains("direct UDP"))
    }

    func testReceiverFailureDegradesAudioWithoutInvokingHostStop() async {
        let host = FakeRemSoundHostOrchestrator(handshake: .init(
            capabilities: makeCapabilities(),
            descriptor: makeDescriptor(senderState: .running)
        ))
        let receiver = FakeRemSoundReceiver()
        let session = RemSoundOrchestrationSession(receiver: receiver, host: host)

        await session.start(
            profile: makeProfile(),
            credentials: HostProfileCredentials(password: "ssh", remSoundPassword: "audio")
        )
        receiver.snapshot.state = .failed("packets stopped")

        XCTAssertEqual(session.state, .degraded("packets stopped"))
        XCTAssertEqual(host.stopSenderCalls, 0)
    }

    func testSenderStatusFailureStaysDegradedWhilePlaybackContinuesAndRecovers() async {
        let host = FakeRemSoundHostOrchestrator(handshake: .init(
            capabilities: makeCapabilities(),
            descriptor: makeDescriptor(senderState: .running)
        ))
        let receiver = FakeRemSoundReceiver()
        let session = RemSoundOrchestrationSession(receiver: receiver, host: host)
        let profile = makeProfile()
        let credentials = HostProfileCredentials(password: "ssh", remSoundPassword: "audio")

        await session.start(profile: profile, credentials: credentials)
        receiver.snapshot.state = .playing
        host.statusError = HostClientError.connectionClosed

        await session.refreshSenderStatus(profile: profile, credentials: credentials)

        guard case .degraded(let message) = session.state else {
            return XCTFail("Expected host-status degradation while playback remains healthy.")
        }
        XCTAssertTrue(message.contains("audio continues"))
        XCTAssertEqual(receiver.snapshot.state, .playing)
        XCTAssertEqual(receiver.stopCalls, 0)

        host.statusError = nil
        await session.refreshSenderStatus(profile: profile, credentials: credentials)

        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(receiver.snapshot.state, .playing)
    }

    func testStopAudioStopsOnlyReceiverAndLeavesSenderUntouched() async {
        let host = FakeRemSoundHostOrchestrator(handshake: .init(
            capabilities: makeCapabilities(),
            descriptor: makeDescriptor(senderState: .running)
        ))
        let receiver = FakeRemSoundReceiver()
        let session = RemSoundOrchestrationSession(receiver: receiver, host: host)

        await session.start(
            profile: makeProfile(),
            credentials: HostProfileCredentials(password: "ssh", remSoundPassword: "audio")
        )
        session.stopAudio()

        XCTAssertEqual(receiver.stopCalls, 1)
        XCTAssertEqual(host.stopSenderCalls, 0)
        XCTAssertEqual(session.state, .stopped)
    }

    func testCapabilityContractRequiresOrchestrationFeatureAndSessionOperation() {
        XCTAssertNoThrow(try RemSoundOrchestrationContract.validate(capabilities: makeCapabilities()))

        let missingFeature = HostCapabilities(
            protocolVersion: 1,
            hostImplementation: "farrelay-host",
            hostVersion: "test",
            operations: ["remsound.session"],
            features: []
        )
        XCTAssertThrowsError(try RemSoundOrchestrationContract.validate(capabilities: missingFeature))

        let missingOperation = HostCapabilities(
            protocolVersion: 1,
            hostImplementation: "farrelay-host",
            hostVersion: "test",
            operations: [],
            features: ["remoteAudioOrchestration"]
        )
        XCTAssertThrowsError(try RemSoundOrchestrationContract.validate(capabilities: missingOperation))
    }

    private func makeProfile(address: String = "g14.example.test") -> HostProfile {
        HostProfile(
            displayName: "G14",
            address: address,
            username: "sebastian",
            platform: .windows,
            farRelayHostCommand: "farrelay-host"
        )
    }

    private func makeCapabilities() -> HostCapabilities {
        HostCapabilities(
            protocolVersion: 1,
            hostImplementation: "farrelay-host",
            hostVersion: "test",
            operations: [
                "capabilities",
                "remsound.status",
                "remsound.start",
                "remsound.stop",
                "remsound.restart",
                "remsound.session",
            ],
            features: ["remoteAudioOrchestration", "remSoundProcessControl"]
        )
    }

    private func makeDescriptor(
        senderState: HostRemSoundLifecycleState
    ) -> HostRemSoundSessionDescriptor {
        HostRemSoundSessionDescriptor(
            transport: "direct_udp",
            audioPort: 47_830,
            discoveryPort: 47_821,
            sampleRateHz: 48_000,
            channels: 2,
            codecs: ["opus", "pcm"],
            sharedPasswordRequired: true,
            peerSelectionRequired: true,
            senderState: senderState,
            senderVersion: "RemSound test"
        )
    }
}

@MainActor
private final class FakeRemSoundReceiver: RemSoundReceiverControlling {
    struct Start: Equatable {
        let host: String
        let port: UInt16
        let password: String
        let targetLatencyMilliseconds: Int
        let autoTuneLatencyEnabled: Bool
    }

    var snapshot = AudioReceiverSnapshot()
    var lastStart: Start?
    var stopCalls = 0
    var reconnectCalls = 0

    func start(
        host: String,
        port: UInt16,
        password: String,
        targetLatencyMilliseconds: Int,
        autoTuneLatencyEnabled: Bool
    ) {
        lastStart = Start(
            host: host,
            port: port,
            password: password,
            targetLatencyMilliseconds: targetLatencyMilliseconds,
            autoTuneLatencyEnabled: autoTuneLatencyEnabled
        )
    }

    func stop() {
        stopCalls += 1
        snapshot.state = .stopped
    }

    func reconnect() {
        reconnectCalls += 1
        snapshot.state = .reconnecting
    }
}

@MainActor
private final class FakeRemSoundHostOrchestrator: RemSoundHostOrchestrating {
    let handshakeValue: RemSoundHostHandshake
    var handshakeCalls = 0
    var statusCalls = 0
    var startSenderCalls = 0
    var stopSenderCalls = 0
    var restartSenderCalls = 0
    var statusError: Error?

    init(handshake: RemSoundHostHandshake) {
        handshakeValue = handshake
    }

    func handshake(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> RemSoundHostHandshake {
        handshakeCalls += 1
        return handshakeValue
    }

    func status(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundStatus {
        statusCalls += 1
        if let statusError { throw statusError }
        return HostRemSoundStatus(
            platformSupported: true,
            installed: true,
            running: true,
            manageable: true,
            state: .running,
            version: "RemSound test",
            executableSource: "installed"
        )
    }

    func startSender(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundActionResult {
        startSenderCalls += 1
        return HostRemSoundActionResult(requested: true, state: .starting)
    }

    func stopSender(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundActionResult {
        stopSenderCalls += 1
        return HostRemSoundActionResult(requested: true, state: .stopping)
    }

    func restartSender(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundActionResult {
        restartSenderCalls += 1
        return HostRemSoundActionResult(requested: true, state: .starting)
    }
}
