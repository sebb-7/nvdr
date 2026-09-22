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
