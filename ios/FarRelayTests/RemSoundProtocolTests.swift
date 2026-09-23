import CryptoKit
import XCTest
@testable import FarRelay

final class RemSoundProtocolTests: XCTestCase {
    func testGoldenWindowsFormatPacketParsesPCMPhaseOneSubset() throws {
        // Fixed little-endian packet vector from the public RemSound wire
        // layout: RMND, v1, Format, stream 0x1234, 48 kHz stereo int24 PCM.
        let packet = try XCTUnwrap(Data(hex: "524D4E44010134127B00000080BB0000020000001800000001000000060000000065040001000000F00000000000000073182B124D200DD00700"))
        let header = try XCTUnwrap(RemSoundPacketHeader.parse(packet))
        XCTAssertEqual(header.type, .format)
        XCTAssertEqual(header.streamID, 0x1234)
        XCTAssertEqual(header.sequence, 123)
        let format = try XCTUnwrap(RemSoundFormat.parse(Data(packet.dropFirst(RemSoundPacketHeader.size))))
        XCTAssertEqual(format.codec, .pcm)
        XCTAssertEqual(format.sampleRate, 48_000)
        XCTAssertEqual(format.channels, 2)
        XCTAssertEqual(format.frameSamplesPerChannel, 240)
        XCTAssertEqual(format.fingerprint, Data(hex: "73182B124D200DD0"))
    }

    func testGoldenPBKDF2AndAESGCMVectorsMatchRemSoundContract() throws {
        XCTAssertEqual(
            RemSoundCrypto.fingerprint(password: "phase1"),
            Data(hex: "73182B124D200DD0")
        )
        // nonce || tag || ciphertext, generated with the upstream documented
        // AES-256-GCM layout and a fixed nonce only for this test vector.
        let encrypted = try XCTUnwrap(Data(hex: "000102030405060708090A0B1F33AC70C536C9CE04BBFB0D3D705745AD605AA78D9E"))
        XCTAssertEqual(RemSoundCrypto.decrypt(encrypted, using: RemSoundCrypto.key(password: "phase1")), Data([1, 2, 3, 4, 5, 6]))
        XCTAssertNil(RemSoundCrypto.decrypt(encrypted, using: RemSoundCrypto.key(password: "wrong password")))
    }

    func testDiscoveryAnnouncementMatchesCurrentWindowsRemSoundContract() throws {
        XCTAssertEqual(RemSoundDiscovery.defaultPort, 47_821)
        XCTAssertEqual(AudioReceiverConfiguration(host: "pc", password: "x").port, 47_830)
        let id = try XCTUnwrap(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
        let announcement = RemSoundDiscoveryAnnouncement(
            instanceID: id,
            name: "FarRelay iOS",
            audioPort: 47_830,
            canSend: false,
            canReceive: true
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: announcement.encoded()) as? [String: Any]
        )
        XCTAssertEqual(object["InstanceId"] as? String, id.uuidString)
        XCTAssertEqual(object["Name"] as? String, "FarRelay iOS")
        XCTAssertEqual(object["AudioPort"] as? Int, 47_830)
        XCTAssertEqual(object["CanSend"] as? Bool, false)
        XCTAssertEqual(object["CanReceive"] as? Bool, true)
        XCTAssertEqual(Set(object.keys), Set(["InstanceId", "Name", "AudioPort", "CanSend", "CanReceive"]))
        XCTAssertEqual(RemSoundDiscoveryAnnouncement.decodeInbound(try announcement.encoded()), announcement)
        XCTAssertNil(RemSoundDiscoveryAnnouncement.decodeInbound(Data("{\"InstanceId\":\"01234567-89AB-CDEF-0123-456789ABCDEF\",\"Name\":\"PC\",\"AudioPort\":0,\"CanSend\":true,\"CanReceive\":true}".utf8)))
        XCTAssertNil(RemSoundDiscoveryAnnouncement.decodeInbound(Data("not json".utf8)))
    }

    func testWindowsHeartbeatPingProducesExactCanonicalPong() throws {
        // Upstream RemSound self-tests use stream 0xFFFF and an Int64 little-
        // endian originator tick. This vector uses tick=42000 and sequence=9.
        let ping = try XCTUnwrap(Data(hex: "524D4E440104FFFF090000000010A4000000000000"))
        let header = try XCTUnwrap(RemSoundPacketHeader.parse(ping))
        XCTAssertEqual(header.type, .heartbeat)
        XCTAssertEqual(header.streamID, 0xFFFF)
        let heartbeat = try XCTUnwrap(RemSoundHeartbeat.parse(Data(ping.dropFirst(RemSoundPacketHeader.size))))
        XCTAssertEqual(heartbeat.kind, .ping)
        XCTAssertEqual(heartbeat.originatorTickMilliseconds, 42_000)

        let pong = try XCTUnwrap(RemSoundHeartbeat.pongResponse(to: ping, sequence: 7))
        XCTAssertEqual(pong, Data(hex: "524D4E440104FFFF070000000110A4000000000000"))
        let pongPayload = try XCTUnwrap(RemSoundHeartbeat.parse(Data(pong.dropFirst(RemSoundPacketHeader.size))))
        XCTAssertEqual(pongPayload.kind, .pong)
        XCTAssertEqual(pongPayload.originatorTickMilliseconds, 42_000)
    }

    func testHeartbeatResponderFailsClosedForPongAndNonHeartbeatPackets() throws {
        let pong = try XCTUnwrap(Data(hex: "524D4E440104FFFF01000000010100000000000000"))
        XCTAssertNil(RemSoundHeartbeat.pongResponse(to: pong, sequence: 2))
        let format = try XCTUnwrap(Data(hex: "524D4E44010134127B00000080BB0000020000001800000001000000060000000065040001000000F00000000000000073182B124D200DD00700"))
        XCTAssertNil(RemSoundHeartbeat.pongResponse(to: format, sequence: 2))
        XCTAssertNil(RemSoundHeartbeat.parse(Data([0])))
    }

    func testOutboundHeartbeatUsesCanonicalWireFormatAndCorrelatesOnlyOurPong() throws {
        var scheduler = RemSoundHeartbeatScheduler()
        let first = scheduler.makePing(monotonicMilliseconds: 1_000)
        let second = scheduler.makePing(monotonicMilliseconds: 2_000)

        XCTAssertEqual(first, Data(hex: "524D4E440104FFFF0100000000E803000000000000"))
        XCTAssertEqual(second, Data(hex: "524D4E440104FFFF0200000000D007000000000000"))

        var matchedPong = try XCTUnwrap(RemSoundHeartbeat.pongResponse(to: first, sequence: 9))
        XCTAssertEqual(scheduler.roundTripMilliseconds(forPong: matchedPong, now: 1_023), 23)
        XCTAssertNil(scheduler.roundTripMilliseconds(forPong: matchedPong, now: 1_024))

        matchedPong[13] = 0xFF // A valid Pong with an originator tick we never sent.
        XCTAssertNil(scheduler.roundTripMilliseconds(forPong: matchedPong, now: 3_000))
    }

    func testSyntacticallyValidOpusFormatIsClassifiedSeparatelyFromMalformed() throws {
        var opus = try XCTUnwrap(Data(hex: "80BB0000020000001800000001000000060000000065040002000000F00000000000000073182B124D200DD0"))
        XCTAssertEqual(RemSoundFormat.classify(opus), .unsupported(.opus))
        opus.removeLast(14)
        XCTAssertEqual(RemSoundFormat.classify(opus), .malformed)
    }

    func testMalformedHeadersAndUnsupportedFormatsFailClosed() throws {
        XCTAssertNil(RemSoundPacketHeader.parse(Data([0x52, 0x4D])))
        var wrongVersion = try XCTUnwrap(Data(hex: "524D4E440201010001000000"))
        XCTAssertNil(RemSoundPacketHeader.parse(wrongVersion))
        wrongVersion[4] = 1
        wrongVersion[5] = 2
        XCTAssertNotNil(RemSoundPacketHeader.parse(wrongVersion))
        XCTAssertNil(RemSoundFormat.parse(Data(repeating: 0, count: 31)))
    }

    func testPCMPartRejectsInvalidIndexes() {
        XCTAssertNil(RemSoundPCMPart.parse(Data([0, 0, 0, 0, 1, 0])))
        XCTAssertNil(RemSoundPCMPart.parse(Data([0, 0, 0, 0, 2, 2])))
    }

    func testPCMAssemblyRejectsOutOfOrderAndBoundsMemory() {
        var assembler = RemSoundPCMFrameAssembler()
        XCTAssertNil(assembler.append(.init(frameID: 4, index: 1, count: 2, encryptedBytes: Data([2]))))
        XCTAssertNil(assembler.append(.init(frameID: 4, index: 0, count: 2, encryptedBytes: Data([1]))))
        XCTAssertEqual(
            assembler.append(.init(frameID: 4, index: 1, count: 2, encryptedBytes: Data([2]))),
            Data([1, 2])
        )
        XCTAssertNil(assembler.append(.init(frameID: 5, index: 0, count: 1, encryptedBytes: Data(repeating: 1, count: 8_193))))
    }

    func testBoundedPCMQueueCannotGrowWithoutLimit() {
        var queue = BoundedPCMQueue(maximumFrames: 4)
        XCTAssertTrue(queue.append(AudioPCMFrame(samples: [0, 0, 0, 0, 0, 0], sampleRate: 48_000, channels: 2)))
        XCTAssertTrue(queue.append(AudioPCMFrame(samples: [0, 0, 0, 0], sampleRate: 48_000, channels: 2)))
        XCTAssertLessThanOrEqual(queue.totalFrameCount, 4)
        XCTAssertFalse(queue.append(AudioPCMFrame(samples: Array(repeating: 0, count: 10), sampleRate: 48_000, channels: 2)))
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(String(hex[index..<next]), radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
