import CryptoKit
import XCTest
@testable import FarRelay

@MainActor
final class RemSoundAudioReceiverInvariantTests: XCTestCase {
    func testAudioLifecycleDoesNotMutateControlPlane() async {
        let bridge = BridgeClient(speech: SpeechOutput())
        let initialStatus = bridge.status
        let initialForwarding = bridge.forwardingEnabled
        let receiver = RemSoundAudioReceiver()
        await receiver.start(configuration: .init(host: "127.0.0.1", port: 47_931, password: "phase1"))
        await receiver.stop()
        XCTAssertEqual(bridge.status, initialStatus)
        XCTAssertEqual(bridge.forwardingEnabled, initialForwarding)
    }

    func testPlaybackFailureDoesNotTerminateControlPlane() async {
        let bridge = BridgeClient(speech: SpeechOutput())
        let receiver = RemSoundAudioReceiver()
        await receiver.playbackFailed()
        let snapshot = await receiver.snapshot()
        XCTAssertEqual(snapshot.state, .failed("Audio playback is unavailable. Reconnect audio to try again."))
        XCTAssertEqual(bridge.status, .idle)
    }

    func testWindowsHeartbeatPingGetsPongWithoutAuthenticatingOrPlaying() async throws {
        let receiver = RemSoundAudioReceiver()
        let ping = try XCTUnwrap(Data(hex: "524D4E440104FFFF090000000010A4000000000000"))
        let reply = await receiver.ingestAndPrepareReply(ping)
        XCTAssertEqual(reply, Data(hex: "524D4E440104FFFF010000000110A4000000000000"))
        let snapshot = await receiver.snapshot()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.statistics.heartbeatPingsReceived, 1)
        XCTAssertEqual(snapshot.statistics.authenticationFailures, 0)
        XCTAssertNil(snapshot.sampleRate)
        XCTAssertNil(snapshot.channelCount)
        XCTAssertEqual(snapshot.statistics.encryptedAudioPacketsReceived, 0)
        XCTAssertEqual(snapshot.statistics.bufferDepthFrames, 0)
    }

    func testValidHeartbeatsOnlyEstablishWaitingForAudioAndEachGetsOnePong() async throws {
        let receiver = RemSoundAudioReceiver()
        await receiver.start(configuration: .init(host: "127.0.0.1", port: 47_940, password: "phase1"))
        let ping = try XCTUnwrap(Data(hex: "524D4E440104FFFF090000000010A4000000000000"))

        let first = await receiver.ingestAndPrepareReply(ping)
        let second = await receiver.ingestAndPrepareReply(ping)
        let snapshot = await receiver.snapshot()

        XCTAssertEqual(first, Data(hex: "524D4E440104FFFF010000000110A4000000000000"))
        XCTAssertEqual(second, Data(hex: "524D4E440104FFFF020000000110A4000000000000"))
        XCTAssertEqual(snapshot.state, .waitingForAudio)
        XCTAssertEqual(snapshot.statistics.heartbeatPingsReceived, 2)
        XCTAssertEqual(snapshot.statistics.authenticationSuccesses, 0)
        XCTAssertEqual(snapshot.statistics.encryptedAudioPacketsReceived, 0)
        XCTAssertEqual(snapshot.statistics.bufferDepthFrames, 0)
        await receiver.stop()
    }

    func testMalformedHeartbeatFailsClosedWithoutChangingControlOrAudioState() async throws {
        let bridge = BridgeClient(speech: SpeechOutput())
        let receiver = RemSoundAudioReceiver()
        let malformedPing = try XCTUnwrap(Data(hex: "524D4E440104FFFF0100000000"))

        let reply = await receiver.ingestAndPrepareReply(malformedPing)
        XCTAssertNil(reply)
        let snapshot = await receiver.snapshot()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.statistics.heartbeatPingsReceived, 0)
        XCTAssertEqual(snapshot.statistics.malformedPackets, 1)
        XCTAssertEqual(snapshot.statistics.bufferDepthFrames, 0)
        XCTAssertEqual(bridge.status, .idle)
    }

    func testHeartbeatPongAndControlPacketsCannotManufactureReplies() async throws {
        let receiver = RemSoundAudioReceiver()
        let pong = try XCTUnwrap(Data(hex: "524D4E440104FFFF01000000010100000000000000"))
        let pongReply = await receiver.ingestAndPrepareReply(pong)
        XCTAssertNil(pongReply)
        let control = try XCTUnwrap(Data(hex: "524D4E4401050100010000000000"))
        let controlReply = await receiver.ingestAndPrepareReply(control)
        XCTAssertNil(controlReply)
        let snapshot = await receiver.snapshot()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.statistics.heartbeatPingsReceived, 0)
    }

    func testAddressCheckEchoesOnlyTheExactChallengeAndNeverChangesAudioState() async throws {
        let receiver = RemSoundAudioReceiver()
        let challenge = try XCTUnwrap(Data(hex: "524D4E44010A010001000000AABBCC"))
        let reply = await receiver.ingestAndPrepareReply(challenge)
        XCTAssertEqual(reply, challenge)

        let snapshot = await receiver.snapshot()
        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.statistics.addrChecksReceived, 1)
        XCTAssertEqual(snapshot.statistics.encryptedAudioPacketsReceived, 0)

        let unrelated = try XCTUnwrap(Data(hex: "524D4E440105010001000000AABBCC"))
        let unrelatedReply = await receiver.ingestAndPrepareReply(unrelated)
        XCTAssertNil(unrelatedReply)
    }

    func testUnsupportedOpusFormatIsNotReportedAsMalformedOrPasswordFailure() async throws {
        let receiver = RemSoundAudioReceiver()
        await receiver.start(configuration: .init(host: "127.0.0.1", port: 47_943, password: "phase1"))
        let opus = try XCTUnwrap(Data(hex: "524D4E44010134127B00000080BB0000020000001800000001000000060000000065040002000000F00000000000000073182B124D200DD00700"))
        await receiver.ingest(opus)
        let snapshot = await receiver.snapshot()
        XCTAssertEqual(snapshot.statistics.formatPacketsReceived, 1)
        XCTAssertEqual(snapshot.statistics.unsupportedFormatPackets, 1)
        XCTAssertEqual(snapshot.statistics.malformedPackets, 0)
        XCTAssertEqual(snapshot.statistics.authenticationFailures, 0)
        await receiver.stop()
    }

    func testStaleAndMalformedPacketsCannotOpenOrContaminateAStream() async throws {
        let receiver = RemSoundAudioReceiver()
        await receiver.start(configuration: .init(host: "127.0.0.1", port: 47_932, password: "phase1"))
        await receiver.ingest(Data([0, 1, 2]))
        var snapshot = await receiver.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.statistics.packetsDropped, 1)

        let format = try XCTUnwrap(Data(hex: "524D4E44010134127B00000080BB0000020000001800000001000000060000000065040001000000F00000000000000073182B124D200DD00700"))
        await receiver.ingest(format)
        let oldStreamAudio = try XCTUnwrap(Data(hex: "524D4E440102785601000000010000000001000102030405060708090A0B1F33AC70C536C9CE04BBFB0D3D705745AD605AA78D9E"))
        await receiver.ingest(oldStreamAudio)
        snapshot = await receiver.snapshot()
        XCTAssertEqual(snapshot.state, .buffering)
        XCTAssertGreaterThanOrEqual(snapshot.statistics.packetsDropped, 2)
        await receiver.stop()
    }

    func testAuthenticatedPCMBuffersThenPlaysWithoutTouchingControlState() async throws {
        let receiver = RemSoundAudioReceiver()
        await receiver.start(configuration: .init(host: "127.0.0.1", port: 47_934, password: "phase1"))
        let format = try XCTUnwrap(Data(hex: "524D4E44010134127B00000080BB0000020000001800000001000000060000000065040001000000F00000000000000073182B124D200DD00700"))
        await receiver.ingest(format)
        for sequence in 1...4 {
            await receiver.ingest(try makeAudioPacket(sequence: UInt32(sequence), frameID: UInt32(sequence)))
        }
        let snapshot = await receiver.snapshot()
        XCTAssertEqual(snapshot.state, .playing)
        XCTAssertEqual(snapshot.sampleRate, 48_000)
        XCTAssertEqual(snapshot.channelCount, 2)
        XCTAssertEqual(snapshot.statistics.authenticationFailures, 0)
        await receiver.stop()
    }

    func testWrongPasswordFailsOnlyWhenFormatFingerprintIsValidated() async throws {
        let bridge = BridgeClient(speech: SpeechOutput())
        let receiver = RemSoundAudioReceiver()
        await receiver.start(configuration: .init(host: "127.0.0.1", port: 47_939, password: "wrong password"))

        let ping = try XCTUnwrap(Data(hex: "524D4E440104FFFF090000000010A4000000000000"))
        let reply = await receiver.ingestAndPrepareReply(ping)
        XCTAssertNotNil(reply)
        var snapshot = await receiver.snapshot()
        XCTAssertEqual(snapshot.statistics.authenticationFailures, 0)
        XCTAssertNotEqual(snapshot.state, .failed("The sender password does not match."))

        await receiver.ingest(try formatPacket())
        snapshot = await receiver.snapshot()
        XCTAssertEqual(snapshot.state, .failed("The sender password does not match."))
        XCTAssertEqual(snapshot.statistics.authenticationFailures, 1)
        XCTAssertEqual(bridge.status, .idle)
        await receiver.stop()
    }

    func testBadEncryptedAudioTagIsAccountedSeparatelyFromWrongPassword() async throws {
        let receiver = RemSoundAudioReceiver()
        await receiver.start(configuration: .init(host: "127.0.0.1", port: 47_941, password: "phase1"))
        await receiver.ingest(try formatPacket())
        var encryptedAudio = try makeAudioPacket(sequence: 1, frameID: 1)
        encryptedAudio[30] ^= 0xFF
        await receiver.ingest(encryptedAudio)

        let snapshot = await receiver.snapshot()
        XCTAssertEqual(snapshot.statistics.authenticationSuccesses, 1)
        XCTAssertEqual(snapshot.statistics.encryptedAudioPacketsReceived, 1)
        XCTAssertEqual(snapshot.statistics.formatAuthenticationFailures, 0)
        XCTAssertEqual(snapshot.statistics.encryptedAudioAuthenticationFailures, 1)
        XCTAssertEqual(snapshot.statistics.bufferDepthFrames, 0)
        XCTAssertEqual(snapshot.statistics.lastError, "Encrypted audio authentication failed.")
        await receiver.stop()
    }

    func testStartStopStartIsDeterministic() async {
        let receiver = RemSoundAudioReceiver()
        let configuration = AudioReceiverConfiguration(host: "127.0.0.1", port: 47_933, password: "phase1")
        await receiver.start(configuration: configuration)
        await receiver.stop()
        let stoppedAfterFirstRun = await receiver.snapshot()
        XCTAssertEqual(stoppedAfterFirstRun.state, .stopped)
        await receiver.start(configuration: configuration)
        let state = (await receiver.snapshot()).state
        XCTAssertTrue(state == .connecting || state == .authenticating)
        await receiver.stop()
    }

    func testRepeatedStartsAndReconnectsReplaceThePriorAudioGeneration() async throws {
        let receiver = RemSoundAudioReceiver()
        let first = AudioReceiverConfiguration(host: "127.0.0.1", port: 47_935, password: "phase1")
        let second = AudioReceiverConfiguration(host: "127.0.0.1", port: 47_936, password: "wrong password")
        await receiver.start(configuration: first)
        await receiver.start(configuration: second)
        await receiver.ingest(try formatPacket())
        let mismatchedSnapshot = await receiver.snapshot()
        XCTAssertEqual(mismatchedSnapshot.state, .failed("The sender password does not match."))

        await receiver.start(configuration: first)
        await receiver.reconnect()
        await receiver.reconnect()
        let snapshot = await receiver.snapshot()
        XCTAssertTrue(snapshot.state == .connecting || snapshot.state == .authenticating)
        XCTAssertEqual(snapshot.statistics.reconnects, 2)
        await receiver.stop()
    }

    func testSenderDisappearanceAndRepeatedStopStayAudioLocal() async throws {
        let bridge = BridgeClient(speech: SpeechOutput())
        let receiver = RemSoundAudioReceiver()
        await receiver.start(configuration: .init(host: "127.0.0.1", port: 47_937, password: "phase1"))
        await receiver.ingest(try formatPacket())
        await receiver.checkSenderLiveness(now: .now.addingTimeInterval(6))
        let unavailableSnapshot = await receiver.snapshot()
        XCTAssertEqual(
            unavailableSnapshot.state,
            .failed("The audio sender stopped or became unreachable. Reconnect audio to try again.")
        )
        XCTAssertEqual(bridge.status, .idle)
        await receiver.stop()
        await receiver.stop()
        let stoppedSnapshot = await receiver.snapshot()
        XCTAssertEqual(stoppedSnapshot.state, .stopped)
    }

    func testOversizedAndFormerStreamPacketsRemainBoundedAndInert() async throws {
        let receiver = RemSoundAudioReceiver()
        await receiver.start(configuration: .init(host: "127.0.0.1", port: 47_938, password: "phase1"))
        await receiver.ingest(Data(repeating: 0, count: 2_049))
        await receiver.ingest(try formatPacket())
        await receiver.ingest(try makeAudioPacket(sequence: 1, frameID: 1, streamID: 0x5678))
        let snapshot = await receiver.snapshot()
        XCTAssertEqual(snapshot.state, .buffering)
        XCTAssertGreaterThanOrEqual(snapshot.statistics.packetsDropped, 2)
        await receiver.stop()
    }
}

private func formatPacket() throws -> Data {
    try XCTUnwrap(Data(hex: "524D4E44010134127B00000080BB0000020000001800000001000000060000000065040001000000F00000000000000073182B124D200DD00700"))
}

private func makeAudioPacket(sequence: UInt32, frameID: UInt32, streamID: UInt16 = 0x1234) throws -> Data {
    var packet = try XCTUnwrap(Data(hex: "524D4E440102341201000000"))
    packet[6] = UInt8(truncatingIfNeeded: streamID)
    packet[7] = UInt8(truncatingIfNeeded: streamID >> 8)
    packet[8] = UInt8(truncatingIfNeeded: sequence)
    packet[9] = UInt8(truncatingIfNeeded: sequence >> 8)
    packet[10] = UInt8(truncatingIfNeeded: sequence >> 16)
    packet[11] = UInt8(truncatingIfNeeded: sequence >> 24)
    packet.append(contentsOf: [
        UInt8(truncatingIfNeeded: frameID),
        UInt8(truncatingIfNeeded: frameID >> 8),
        UInt8(truncatingIfNeeded: frameID >> 16),
        UInt8(truncatingIfNeeded: frameID >> 24),
        0,
        1,
    ])
    let nonceData = Data(repeating: UInt8(truncatingIfNeeded: frameID), count: 12)
    let nonce = try AES.GCM.Nonce(data: nonceData)
    let sealed = try AES.GCM.seal(Data(repeating: 0, count: 1_440), using: RemSoundCrypto.key(password: "phase1"), nonce: nonce)
    packet.append(nonceData)
    packet.append(sealed.tag)
    packet.append(sealed.ciphertext)
    return packet
}
