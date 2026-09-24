import Foundation

/// Pure, bounded copy of the latency recommendation rule used by RemSoundApple.
/// It deliberately consumes only per-second measurements so packet and render paths
/// never publish high-frequency SwiftUI updates.
struct RemSoundLatencyAutoTune: Sendable {
    static let safetyMarginMilliseconds = 5
    static let hysteresisMilliseconds = 5
    static let recommendationCapMilliseconds = 200
    static let maximumDecreasePerTickMilliseconds = 5
    static let lookbackSeconds = 15

    struct Sample: Sendable, Equatable {
        var arrivalGapMilliseconds: Int
        var renderGapMilliseconds: Int
    }

    enum Decision: Sendable, Equatable {
        case hold(String)
        case retarget(Int)
    }

    static func decide(
        samples: [Sample],
        frameMilliseconds: Int,
        currentTargetMilliseconds: Int,
        minimumTargetMilliseconds: Int,
        maximumTargetMilliseconds: Int,
        tuneBlockingUnderruns: Int
    ) -> Decision {
        guard samples.count >= 2 else { return .hold("waiting for history") }
        guard tuneBlockingUnderruns == 0 else { return .hold("producer starvation") }
        let window = samples.suffix(lookbackSeconds)
        let arrival = secondHighest(window.map(\.arrivalGapMilliseconds), floor: 0)
        let render = secondHighest(window.map(\.renderGapMilliseconds), floor: 2)
        let codecFloor = Int((Double(frameMilliseconds) * 1.5).rounded(.up))
        let recommendation = min(max(codecFloor, arrival + render + safetyMarginMilliseconds), recommendationCapMilliseconds)
        let proposed = recommendation > currentTargetMilliseconds
            ? recommendation
            : max(recommendation, currentTargetMilliseconds - maximumDecreasePerTickMilliseconds)
        let clamped = min(max(proposed, minimumTargetMilliseconds), maximumTargetMilliseconds)
        guard abs(clamped - currentTargetMilliseconds) >= hysteresisMilliseconds else {
            return .hold("within hysteresis")
        }
        return .retarget(clamped)
    }

    private static func secondHighest(_ values: [Int], floor: Int) -> Int {
        var highest = floor
        var second = floor
        for value in values {
            if value > highest { second = highest; highest = value }
            else if value > second { second = value }
        }
        return values.count >= 2 ? second : highest
    }
}

struct RemSoundPlayoutMetrics: Sendable, Equatable {
    var bufferedFrames = 0
    var targetFrames = 0
    var isArmed = false
    var underruns = 0
    var tuneBlockingUnderruns = 0
    var deviceGulpUnderruns = 0
    var concealedFrames = 0
    var trimEvents = 0
    var droppedFrames = 0
    var peakRenderGapMilliseconds = 0
}

/// The only shared mutable object between the receiver actor (producer) and
/// AVAudioEngine's real-time source callback (consumer). All input is fixed
/// 48 kHz interleaved stereo and capacity is fixed, so network input cannot
/// grow memory or force allocation on the render path.
final class RemSoundPlayoutBuffer: @unchecked Sendable {
    static let sampleRate = 48_000
    static let channels = 2
    private static let fadeFrames = 32
    private static let maximumEmptyReads = 8
    private static let starvationThresholdFrames = 144 // 3 ms

    private let lock = NSLock()
    private let capacityFrames: Int
    private var ring: [Float]
    private var head = 0
    private var tail = 0
    private var count = 0
    private var targetFrames = 960
    private var armed = false
    private var consecutiveEmptyReads = 0
    private var fadeInPending = true
    private var lastLeft: Float = 0
    private var lastRight: Float = 0
    private var largestWriteFrames = 0
    private var filteredError = 0.0
    private var lastErrorSampleNanoseconds: UInt64 = 0
    private var lastRenderNanoseconds: UInt64 = 0
    private var peakRenderGapMilliseconds = 0
    private var underruns = 0
    private var tuneBlockingUnderruns = 0
    private var deviceGulpUnderruns = 0
    private var concealedFrames = 0
    private var trimEvents = 0
    private var droppedFrames = 0

    init(capacityFrames: Int = sampleRate * 2) {
        self.capacityFrames = max(capacityFrames, 1)
        ring = [Float](repeating: 0, count: self.capacityFrames * Self.channels)
    }

    func reset(targetFrames: Int) {
        lock.lock(); defer { lock.unlock() }
        head = 0; tail = 0; count = 0
        self.targetFrames = min(max(targetFrames, 1), capacityFrames)
        armed = false; consecutiveEmptyReads = 0; fadeInPending = true
        lastLeft = 0; lastRight = 0; largestWriteFrames = 0
        filteredError = 0; lastErrorSampleNanoseconds = 0; lastRenderNanoseconds = 0
        peakRenderGapMilliseconds = 0; underruns = 0; tuneBlockingUnderruns = 0
        deviceGulpUnderruns = 0; concealedFrames = 0; trimEvents = 0; droppedFrames = 0
    }

    func setTargetFrames(_ frames: Int, drainOnLower: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        let newTarget = min(max(frames, 1), capacityFrames)
        if drainOnLower, newTarget < targetFrames, count > newTarget {
            dropOldestLocked(count - newTarget)
            fadeInPending = true
        }
        targetFrames = newTarget
    }

    func write(_ samples: [Float]) {
        let frames = samples.count / Self.channels
        guard frames > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        largestWriteFrames = max(largestWriteFrames, min(frames, capacityFrames))
        let keptFrames = min(frames, capacityFrames)
        let sourceStart = (frames - keptFrames) * Self.channels
        if count + keptFrames > capacityFrames {
            dropOldestLocked(count + keptFrames - capacityFrames)
            fadeInPending = true
        }
        var source = sourceStart
        var remaining = keptFrames
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - tail)
            let destination = tail * Self.channels
            for index in 0..<(chunk * Self.channels) { ring[destination + index] = samples[source + index] }
            source += chunk * Self.channels
            tail = (tail + chunk) % capacityFrames
            remaining -= chunk
        }
        count += keptFrames

        // Keep a packet-aware cushion above target. This rejects stale burst backlog
        // without trimming to the fragile bare target.
        let margin = max(largestWriteFrames * 4 + 4 * Self.sampleRate / 1_000, 15 * Self.sampleRate / 1_000) + 8 * Self.sampleRate / 1_000
        if armed, count > targetFrames + margin {
            let keep = min(capacityFrames, targetFrames + largestWriteFrames * 2 + 5 * Self.sampleRate / 1_000)
            if count > keep {
                dropOldestLocked(count - keep)
                trimEvents += 1
                fadeInPending = true
            }
        }
    }

    /// Called only from the AVAudioSourceNode callback. `output` is interleaved stereo.
    func render(into output: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        for index in 0..<(frames * Self.channels) { output[index] = 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        if lastRenderNanoseconds != 0 {
            let gap = Int((now &- lastRenderNanoseconds) / 1_000_000)
            peakRenderGapMilliseconds = max(peakRenderGapMilliseconds, gap)
        }
        lastRenderNanoseconds = now
        updateFilteredErrorLocked(now: now)

        if !armed {
            guard count >= targetFrames else { return }
            armed = true
            consecutiveEmptyReads = 0
            fadeInPending = true
        }
        let available = min(count, frames)
        if available < frames {
            concealedFrames += frames - available
            if available == 0 || filteredError <= -Double(Self.starvationThresholdFrames) { tuneBlockingUnderruns += 1 }
            else { deviceGulpUnderruns += 1 }
            underruns += 1
        }
        guard available > 0 else {
            consecutiveEmptyReads += 1
            applyFadeOutLocked(into: output, frames: min(frames, Self.fadeFrames))
            if consecutiveEmptyReads >= Self.maximumEmptyReads { armed = false }
            return
        }
        if consecutiveEmptyReads > 0 { fadeInPending = true; consecutiveEmptyReads = 0 }
        var produced = 0
        var remaining = available
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - head)
            let source = head * Self.channels
            let destination = produced * Self.channels
            for index in 0..<(chunk * Self.channels) { output[destination + index] = ring[source + index] }
            head = (head + chunk) % capacityFrames
            produced += chunk
            remaining -= chunk
        }
        count -= available
        if fadeInPending {
            applyFadeInLocked(into: output, frames: min(available, Self.fadeFrames))
            fadeInPending = false
        }
        let final = (available - 1) * Self.channels
        lastLeft = output[final]; lastRight = output[final + 1]
        if available < frames {
            applyFadeOutAtBoundaryLocked(into: output, startFrame: available, frames: min(available, Self.fadeFrames))
            fadeInPending = true
        }
    }

    /// AVAudioEngine standard Float32 stereo is non-interleaved. Keep the
    /// ring interleaved for compact producer writes, but deinterleave directly
    /// into the engine's two channel buffers without allocating on the render path.
    func render(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        guard frames > 0 else { return }
        lock.lock(); defer { lock.unlock() }

        for frame in 0..<frames {
            left[frame] = 0
            right[frame] = 0
        }

        let now = DispatchTime.now().uptimeNanoseconds
        if lastRenderNanoseconds != 0 {
            let gap = Int((now &- lastRenderNanoseconds) / 1_000_000)
            peakRenderGapMilliseconds = max(peakRenderGapMilliseconds, gap)
        }
        lastRenderNanoseconds = now
        updateFilteredErrorLocked(now: now)

        if !armed {
            guard count >= targetFrames else { return }
            armed = true
            consecutiveEmptyReads = 0
            fadeInPending = true
        }

        let available = min(count, frames)
        if available < frames {
            concealedFrames += frames - available
            if available == 0 || filteredError <= -Double(Self.starvationThresholdFrames) {
                tuneBlockingUnderruns += 1
            } else {
                deviceGulpUnderruns += 1
            }
            underruns += 1
        }

        guard available > 0 else {
            consecutiveEmptyReads += 1
            applyFadeOutLocked(
                left: left,
                right: right,
                frames: min(frames, Self.fadeFrames)
            )
            if consecutiveEmptyReads >= Self.maximumEmptyReads { armed = false }
            return
        }

        if consecutiveEmptyReads > 0 {
            fadeInPending = true
            consecutiveEmptyReads = 0
        }

        var produced = 0
        var remaining = available
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - head)
            let source = head * Self.channels
            for frame in 0..<chunk {
                left[produced + frame] = ring[source + frame * Self.channels]
                right[produced + frame] = ring[source + frame * Self.channels + 1]
            }
            head = (head + chunk) % capacityFrames
            produced += chunk
            remaining -= chunk
        }
        count -= available

        if fadeInPending {
            applyFadeInLocked(
                left: left,
                right: right,
                frames: min(available, Self.fadeFrames)
            )
            fadeInPending = false
        }

        lastLeft = left[available - 1]
        lastRight = right[available - 1]

        if available < frames {
            applyFadeOutAtBoundaryLocked(
                left: left,
                right: right,
                startFrame: available,
                frames: min(available, Self.fadeFrames)
            )
            fadeInPending = true
        }
    }

    func metrics(resetPeakRenderGap: Bool = false) -> RemSoundPlayoutMetrics {
        lock.lock(); defer { lock.unlock() }
        let result = RemSoundPlayoutMetrics(bufferedFrames: count, targetFrames: targetFrames, isArmed: armed, underruns: underruns, tuneBlockingUnderruns: tuneBlockingUnderruns, deviceGulpUnderruns: deviceGulpUnderruns, concealedFrames: concealedFrames, trimEvents: trimEvents, droppedFrames: droppedFrames, peakRenderGapMilliseconds: peakRenderGapMilliseconds)
        if resetPeakRenderGap { peakRenderGapMilliseconds = 0 }
        return result
    }

    private func dropOldestLocked(_ frames: Int) {
        let removed = min(max(frames, 0), count)
        head = (head + removed) % capacityFrames
        count -= removed
        droppedFrames += removed
    }

    private func updateFilteredErrorLocked(now: UInt64) {
        defer { lastErrorSampleNanoseconds = now }
        guard lastErrorSampleNanoseconds != 0 else { return }
        let delta = Double(now &- lastErrorSampleNanoseconds) / 1_000_000_000
        let alpha = delta / (2 + delta)
        filteredError = (1 - alpha) * filteredError + alpha * Double(count - targetFrames)
    }

    private func applyFadeInLocked(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        guard frames > 0 else { return }
        for frame in 0..<frames {
            let gain = Float(frame + 1) / Float(frames)
            left[frame] *= gain
            right[frame] *= gain
        }
    }

    private func applyFadeOutAtBoundaryLocked(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        startFrame: Int,
        frames: Int
    ) {
        guard frames > 0 else { return }
        for offset in 0..<frames {
            let frame = startFrame - frames + offset
            guard frame >= 0 else { continue }
            let gain = Float(frames - offset) / Float(frames)
            left[frame] *= gain
            right[frame] *= gain
        }
    }

    private func applyFadeOutLocked(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        guard frames > 0 else { return }
        for frame in 0..<frames {
            let gain = Float(frames - frame) / Float(frames)
            left[frame] = lastLeft * gain
            right[frame] = lastRight * gain
        }
    }

    private func applyFadeInLocked(into output: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        for frame in 0..<frames {
            let gain = Float(frame + 1) / Float(frames)
            output[frame * 2] *= gain; output[frame * 2 + 1] *= gain
        }
    }

    private func applyFadeOutAtBoundaryLocked(into output: UnsafeMutablePointer<Float>, startFrame: Int, frames: Int) {
        guard frames > 0 else { return }
        for offset in 0..<frames {
            let frame = startFrame - frames + offset
            guard frame >= 0 else { continue }
            let gain = Float(frames - offset) / Float(frames)
            output[frame * 2] *= gain; output[frame * 2 + 1] *= gain
        }
    }

    private func applyFadeOutLocked(into output: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        for frame in 0..<frames {
            let gain = Float(frames - frame) / Float(frames)
            output[frame * 2] = lastLeft * gain; output[frame * 2 + 1] = lastRight * gain
        }
    }
}
