import Foundation

struct RemSoundPCMFrameAssembler: Sendable {
    private static let maximumEncryptedFrameBytes = 8_192
    private var pendingID: UInt32?
    private var expectedIndex: UInt8 = 0
    private var partCount: UInt8 = 0
    private var bytes = Data()

    mutating func append(_ part: RemSoundPCMPart) -> Data? {
        if part.index == 0 {
            pendingID = part.frameID
            expectedIndex = 0
            partCount = part.count
            bytes.removeAll(keepingCapacity: true)
        }
        guard pendingID == part.frameID,
              expectedIndex == part.index,
              partCount == part.count,
              bytes.count + part.encryptedBytes.count <= Self.maximumEncryptedFrameBytes
        else {
            reset()
            return nil
        }
        bytes.append(part.encryptedBytes)
        expectedIndex &+= 1
        guard expectedIndex == partCount else { return nil }
        let completed = bytes
        reset()
        return completed
    }

    mutating func reset() {
        pendingID = nil
        expectedIndex = 0
        partCount = 0
        bytes.removeAll(keepingCapacity: true)
    }
}

struct BoundedPCMQueue: Sendable {
    private(set) var frames: [AudioPCMFrame] = []
    private(set) var totalFrameCount = 0
    let maximumFrames: Int

    init(maximumFrames: Int = 48_000 * 2) {
        self.maximumFrames = maximumFrames
    }

    mutating func append(_ frame: AudioPCMFrame) -> Bool {
        let incoming = frame.samples.count / max(frame.channels, 1)
        guard incoming <= maximumFrames else { return false }
        while totalFrameCount + incoming > maximumFrames, let removed = frames.first {
            frames.removeFirst()
            totalFrameCount -= removed.samples.count / max(removed.channels, 1)
        }
        frames.append(frame)
        totalFrameCount += incoming
        return true
    }

    mutating func popFirst() -> AudioPCMFrame? {
        guard !frames.isEmpty else { return nil }
        let value = frames.removeFirst()
        totalFrameCount -= value.samples.count / max(value.channels, 1)
        return value
    }
}
