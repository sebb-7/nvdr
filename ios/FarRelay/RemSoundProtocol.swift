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

/// Cross-port peer-discovery contract used by the current Windows RemSound app.
/// Audio remains on 47830; discovery is a separate best-effort UDP announcement
/// channel on 47821. Direct unicast is sufficient for both LAN and Tailscale:
/// once Windows receives our announcement it learns the source address and
/// starts announcing back to it as a known peer.
enum RemSoundDiscovery {
    static let defaultPort: UInt16 = 47_821
    static let announcementInterval: Duration = .milliseconds(1_500)
}

struct RemSoundDiscoveryAnnouncement: Codable, Equatable, Sendable {
    let instanceID: UUID
    let name: String
    let audioPort: Int
    let canSend: Bool
    let canReceive: Bool

    enum CodingKeys: String, CodingKey {
        case instanceID = "InstanceId"
        case name = "Name"
        case audioPort = "AudioPort"
        case canSend = "CanSend"
        case canReceive = "CanReceive"
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decodeInbound(_ data: Data) -> Self? {
        guard let announcement = try? JSONDecoder().decode(Self.self, from: data),
              !announcement.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65_535).contains(announcement.audioPort)
        else { return nil }
        return announcement
    }
}

/// Current desktop RemSound determines whether a selected peer is online with
/// a one-second heartbeat on the same UDP port as audio. A Ping contains an
/// originator-owned monotonic timestamp; the peer must echo that exact value in
/// a Pong. The timestamp is not authentication and must never advance FarRelay
/// audio state by itself.
enum RemSoundHeartbeatKind: UInt8, Sendable {
    case ping = 0
    case pong = 1
}

struct RemSoundHeartbeat: Equatable, Sendable {
    static let payloadSize = 9
    static let streamID: UInt16 = 0xFFFF

    let kind: RemSoundHeartbeatKind
    let originatorTickMilliseconds: Int64

    static func parse(_ payload: Data) -> Self? {
        guard payload.count >= payloadSize,
              let kind = RemSoundHeartbeatKind(rawValue: payload[0]),
              let tick = payload.int64LE(at: 1)
        else { return nil }
        return Self(kind: kind, originatorTickMilliseconds: tick)
    }

    static func ping(sequence: UInt32, originatorTickMilliseconds: Int64) -> Data {
        var packet = Data()
        packet.reserveCapacity(RemSoundPacketHeader.size + payloadSize)
        packet.appendUInt32LE(RemSoundPacketHeader.magic)
        packet.append(RemSoundPacketHeader.version)
        packet.append(RemSoundPacketType.heartbeat.rawValue)
        packet.appendUInt16LE(streamID)
        packet.appendUInt32LE(sequence)
        packet.append(RemSoundHeartbeatKind.ping.rawValue)
        packet.appendInt64LE(originatorTickMilliseconds)
        return packet
    }

    /// Produces the exact Pong Windows RemSound expects for a Ping. Non-Ping
    /// datagrams return nil so unrelated packets can never manufacture replies.
    static func pongResponse(to datagram: Data, sequence: UInt32) -> Data? {
        guard datagram.count >= RemSoundPacketHeader.size + payloadSize,
              let header = RemSoundPacketHeader.parse(datagram),
              header.type == .heartbeat,
              let heartbeat = parse(Data(datagram.dropFirst(RemSoundPacketHeader.size))),
              heartbeat.kind == .ping
        else { return nil }

        var response = Data()
        response.reserveCapacity(RemSoundPacketHeader.size + payloadSize)
        response.appendUInt32LE(RemSoundPacketHeader.magic)
        response.append(RemSoundPacketHeader.version)
        response.append(RemSoundPacketType.heartbeat.rawValue)
        response.appendUInt16LE(streamID)
        response.appendUInt32LE(sequence)
        response.append(RemSoundHeartbeatKind.pong.rawValue)
        response.appendInt64LE(heartbeat.originatorTickMilliseconds)
        return response
    }
}

/// Pure heartbeat state used by the receiver's one-second scheduler. The
/// explicit tick input keeps wire and correlation invariants deterministic in
/// tests while production supplies a process-monotonic clock.
struct RemSoundHeartbeatScheduler: Sendable {
    static let cadence: Duration = .seconds(1)
    private static let maximumOutstandingPings = 8
    private var sequence: UInt32 = 0
    private var outstandingPings: [Int64: Int64] = [:]

    mutating func makePing(monotonicMilliseconds: Int64) -> Data {
        sequence &+= 1
        outstandingPings[monotonicMilliseconds] = monotonicMilliseconds
        if outstandingPings.count > Self.maximumOutstandingPings,
           let oldest = outstandingPings.keys.min() {
            outstandingPings.removeValue(forKey: oldest)
        }
        return RemSoundHeartbeat.ping(
            sequence: sequence,
            originatorTickMilliseconds: monotonicMilliseconds
        )
    }

    mutating func roundTripMilliseconds(forPong datagram: Data, now: Int64) -> Int? {
        guard let header = RemSoundPacketHeader.parse(datagram),
              header.type == .heartbeat,
              let heartbeat = RemSoundHeartbeat.parse(Data(datagram.dropFirst(RemSoundPacketHeader.size))),
              heartbeat.kind == .pong,
              outstandingPings.removeValue(forKey: heartbeat.originatorTickMilliseconds) != nil
        else { return nil }
        return Int(max(0, now - heartbeat.originatorTickMilliseconds))
    }
}

enum RemSoundCodec: Int, Equatable, Sendable {
    case pcm = 1
    case opus = 2
}

enum RemSoundRenderRoute: UInt8, Equatable, Sendable {
    case mixed = 0
    case wasapi = 1
    case asio = 2
}

/// Windows does not send a named profile: the current Opus profile is
/// determined by its frame duration. Tight/live uses 2.5 or 5 ms frames;
/// normal streams use 10 ms or longer frames.
enum RemSoundOpusMode: String, Equatable, Sendable {
    case broadcast = "Broadcast"
    case live = "Live"
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
    let lane: RemSoundRenderRoute
    let fingerprint: Data?
    let captureLatencyMilliseconds: Double?

    var frameDurationMilliseconds: Double {
        Double(frameSamplesPerChannel) * 1_000 / Double(sampleRate)
    }

    var opusMode: RemSoundOpusMode? {
        guard codec == .opus else { return nil }
        return frameSamplesPerChannel <= 240 ? .live : .broadcast
    }

    enum ParseResult: Equatable, Sendable {
        case supported(RemSoundFormat)
        case unsupported(Int)
        case malformed
    }

    static func parse(_ payload: Data) -> RemSoundFormat? {
        guard case .supported(let format) = classify(payload) else { return nil }
        return format
    }

    static func classify(_ payload: Data) -> ParseResult {
        guard payload.count >= minimumPayloadSize,
              let rawCodec = payload.int32LE(at: 24),
              let sampleRate = payload.int32LE(at: 0),
              let channels = payload.int32LE(at: 4),
              let bitsPerSample = payload.int32LE(at: 8),
              let encoding = payload.int32LE(at: 12),
              let blockAlign = payload.int32LE(at: 16),
              let bytesPerSecond = payload.int32LE(at: 20),
              let frameSamples = payload.int32LE(at: 28)
        else { return .malformed }

        guard let codec = RemSoundCodec(rawValue: Int(rawCodec)) else {
            return .unsupported(Int(rawCodec))
        }

        // Exact current Windows sender contracts. Format packets are not
        // encrypted, so this allow-list also bounds native decoder allocation.
        let validPCM = codec == .pcm
            && sampleRate == 48_000 && channels == 2
            && bitsPerSample == 24 && encoding == 1
            && blockAlign == 6 && bytesPerSecond == 288_000
            && (120...240).contains(frameSamples)
        let validOpus = codec == .opus
            && sampleRate == 48_000 && channels == 2
            && bitsPerSample == 16 && encoding == 1
            && blockAlign == 4 && bytesPerSecond == 192_000
            && (120...2_880).contains(frameSamples)
        guard validPCM || validOpus else { return .unsupported(Int(rawCodec)) }

        let lane: RemSoundRenderRoute
        if payload.count >= 36 {
            guard payload[33] == 0, payload[34] == 0, payload[35] == 0 else {
                return .malformed
            }
            // Current upstream maps unrecognized lane values to Mixed. FarRelay
            // has one renderer, but retains the field for diagnostics.
            lane = RemSoundRenderRoute(rawValue: payload[32]) ?? .mixed
        } else {
            lane = .mixed
        }

        let fingerprint = payload.count >= fingerprintPayloadSize
            ? payload.subdata(in: 36..<44)
            : nil
        let captureLatencyMilliseconds = payload.count >= captureLatencyPayloadSize
            ? Double(payload.uint16LE(at: 44) ?? 0) / 10
            : nil
        return .supported(Self(
            sampleRate: Int(sampleRate),
            channels: Int(channels),
            bitsPerSample: Int(bitsPerSample),
            encoding: Int(encoding),
            blockAlign: Int(blockAlign),
            bytesPerSecond: Int(bytesPerSecond),
            codec: codec,
            frameSamplesPerChannel: Int(frameSamples),
            lane: lane,
            fingerprint: fingerprint,
            captureLatencyMilliseconds: captureLatencyMilliseconds
        ))
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

    func int64LE(at offset: Int) -> Int64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var value: UInt64 = 0
        for byteOffset in 0..<8 {
            value |= UInt64(self[offset + byteOffset]) << UInt64(byteOffset * 8)
        }
        return Int64(bitPattern: value)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendInt64LE(_ value: Int64) {
        let bits = UInt64(bitPattern: value)
        for byteOffset in 0..<8 {
            append(UInt8(truncatingIfNeeded: bits >> UInt64(byteOffset * 8)))
        }
    }
}
