import CryptoKit
import Foundation

enum RemSoundPacketType: UInt8, Sendable {
    case format = 1
    case audio = 2
    case keepAlive = 3
    case heartbeat = 4
    case control = 5
    case addressCheck = 10
}

struct RemSoundPacketHeader: Equatable, Sendable {
    static let size = 12
    static let magic: UInt32 = 0x444E4D52
    static let version: UInt8 = 1

    let type: RemSoundPacketType
    let streamID: UInt16
    let sequence: UInt32

    static func parse(_ data: Data) -> RemSoundPacketHeader? {
        guard data.count >= size,
              data.uint32LE(at: 0) == magic,
              data[4] == version,
              let type = RemSoundPacketType(rawValue: data[5]),
              let rawStreamID = data.uint16LE(at: 6),
              let sequence = data.uint32LE(at: 8)
        else { return nil }
        return Self(type: type, streamID: rawStreamID == 0 ? 1 : rawStreamID, sequence: sequence)
    }
}

enum RemSoundCodec: Int, Sendable {
    case pcm = 1
    case opus = 2
}

struct RemSoundFormat: Equatable, Sendable {
    static let minimumPayloadSize = 32
    static let fingerprintPayloadSize = 44
    static let captureLatencyPayloadSize = 46

    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    let encoding: Int
    let blockAlign: Int
    let bytesPerSecond: Int
    let codec: RemSoundCodec
    let frameSamplesPerChannel: Int
    let fingerprint: Data?

    static func parse(_ payload: Data) -> RemSoundFormat? {
        guard payload.count >= minimumPayloadSize,
              let codec = RemSoundCodec(rawValue: Int(payload.int32LE(at: 24) ?? -1)),
              let sampleRate = payload.int32LE(at: 0),
              let channels = payload.int32LE(at: 4),
              let bitsPerSample = payload.int32LE(at: 8),
              let encoding = payload.int32LE(at: 12),
              let blockAlign = payload.int32LE(at: 16),
              let bytesPerSecond = payload.int32LE(at: 20),
              let frameSamples = payload.int32LE(at: 28)
        else { return nil }

        // Phase 1 intentionally accepts only the Windows sender's smallest
        // interoperable stream. Unknown or future formats fail closed.
        guard codec == .pcm,
              sampleRate == 48_000,
              channels == 2,
              bitsPerSample == 24,
              encoding == 1,
              blockAlign == 6,
              bytesPerSecond == 288_000,
              (120...240).contains(frameSamples)
        else { return nil }

        let fingerprint = payload.count >= fingerprintPayloadSize
            ? payload.subdata(in: 36..<44)
            : nil
        return Self(
            sampleRate: Int(sampleRate),
            channels: Int(channels),
            bitsPerSample: Int(bitsPerSample),
            encoding: Int(encoding),
            blockAlign: Int(blockAlign),
            bytesPerSecond: Int(bytesPerSecond),
            codec: codec,
            frameSamplesPerChannel: Int(frameSamples),
            fingerprint: fingerprint
        )
    }
}

struct RemSoundPCMPart: Equatable, Sendable {
    static let headerSize = 6
    let frameID: UInt32
    let index: UInt8
    let count: UInt8
    let encryptedBytes: Data

    static func parse(_ payload: Data) -> Self? {
        guard payload.count >= headerSize,
              let frameID = payload.uint32LE(at: 0)
        else { return nil }
        let index = payload[4]
        let count = payload[5]
        guard count > 0, index < count else { return nil }
        return Self(frameID: frameID, index: index, count: count, encryptedBytes: Data(payload.dropFirst(headerSize)))
    }
}

enum RemSoundCrypto {
    static let encryptionOverhead = 28
    private static let keySalt = Data("RemSound.v1.audio-key".utf8)
    private static let fingerprintSalt = Data("RemSound.v1.fingerprint".utf8)

    static func key(password: String) -> SymmetricKey {
        SymmetricKey(data: pbkdf2(password: password, salt: keySalt, outputLength: 32))
    }

    static func fingerprint(password: String) -> Data {
        pbkdf2(password: password, salt: fingerprintSalt, outputLength: 8)
    }

    static func fingerprintsMatch(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.enumerated().reduce(UInt8(0)) { partial, element in
            partial | (element.element ^ rhs[element.offset])
        } == 0
    }

    static func decrypt(_ packet: Data, using key: SymmetricKey) -> Data? {
        guard packet.count >= encryptionOverhead else { return nil }
        do {
            let nonce = try AES.GCM.Nonce(data: packet.prefix(12))
            let tag = packet.subdata(in: 12..<28)
            let ciphertext = packet.dropFirst(28)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key)
        } catch {
            return nil
        }
    }

    private static func pbkdf2(password: String, salt: Data, outputLength: Int) -> Data {
        let passwordKey = SymmetricKey(data: Data(password.utf8))
        let blocks = (outputLength + SHA256.Digest.byteCount - 1) / SHA256.Digest.byteCount
        var output = Data()
        for index in 1...blocks {
            var counter = UInt32(index).bigEndian
            var input = salt
            withUnsafeBytes(of: &counter) { input.append(contentsOf: $0) }
            var value = Data(HMAC<SHA256>.authenticationCode(for: input, using: passwordKey))
            var block = value
            for _ in 1..<100_000 {
                value = Data(HMAC<SHA256>.authenticationCode(for: value, using: passwordKey))
                for offset in block.indices { block[offset] ^= value[offset] }
            }
            output.append(block)
        }
        return output.prefix(outputLength)
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func int32LE(at offset: Int) -> Int32? {
        uint32LE(at: offset).map { Int32(bitPattern: $0) }
    }
}
