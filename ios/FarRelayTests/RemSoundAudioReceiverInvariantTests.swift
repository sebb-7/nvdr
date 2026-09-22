import CryptoKit
import XCTest
@testable import FarRelay

@MainActor
final class RemSoundAudioReceiverInvariantTests: XCTestCase {
    func testAudioLifecycleDoesNotMutateControlPlane() async {
        let bridge = BridgeClient(speech: SpeechOutput())
        let receiver = RemSoundAudioReceiver()
        await receiver.start(configuration: .init(host: "127.0.0.1", port: 47_931, password: "phase1"))
        await receiver.stop()
        XCTAssertEqual(bridge.status, .idle)
        XCTAssertFalse(bridge.forwardingEnabled)
    }

    func testPlaybackFailureDoesNotTerminateControlPlane() async {
        let bridge = BridgeClient(speech: SpeechOutput())
        let receiver = RemSoundAudioReceiver()
        await receiver.playbackFailed()
        let snapshot = await receiver.snapshot()
        XCTAssertEqual(snapshot.state, .failed("Audio playback is unavailable. Reconnect audio to try again."))
        XCTAssertEqual(bridge.status, .idle)
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
