import XCTest
@testable import FarRelay

final class RemSoundPlayoutTests: XCTestCase {
    private func samples(_ value: Float, frames: Int) -> [Float] {
        Array(repeating: value, count: frames * 2)
    }

    private func render(_ buffer: RemSoundPlayoutBuffer, frames: Int) -> [Float] {
        var output = samples(0, frames: frames)
        output.withUnsafeMutableBufferPointer { pointer in
            buffer.render(into: pointer.baseAddress!, frames: frames)
        }
        return output
    }

    func testDoesNotPlayBeforeTargetAndArmsAtTarget() {
        let buffer = RemSoundPlayoutBuffer(capacityFrames: 2_000)
        buffer.reset(targetFrames: 480)
        buffer.write(samples(0.5, frames: 240))
        XCTAssertTrue(render(buffer, frames: 120).allSatisfy { $0 == 0 })
        XCTAssertFalse(buffer.metrics().isArmed)

        buffer.write(samples(0.5, frames: 360))
        XCTAssertTrue(render(buffer, frames: 120).contains { $0 != 0 })
        XCTAssertTrue(buffer.metrics().isArmed)
    }

    func testStarvationDisarmsAndRequiresAFullRearmTarget() {
        let buffer = RemSoundPlayoutBuffer(capacityFrames: 2_000)
        buffer.reset(targetFrames: 240)
        buffer.write(samples(0.5, frames: 240))
        _ = render(buffer, frames: 240)
        for _ in 0..<8 { _ = render(buffer, frames: 120) }
        XCTAssertFalse(buffer.metrics().isArmed)
        buffer.write(samples(0.5, frames: 120))
        XCTAssertTrue(render(buffer, frames: 60).allSatisfy { $0 == 0 })
    }

    func testBoundedCapacityKeepsFreshAudio() {
        let buffer = RemSoundPlayoutBuffer(capacityFrames: 4)
        buffer.reset(targetFrames: 1)
        buffer.write(samples(0.25, frames: 4))
        _ = render(buffer, frames: 1)
        buffer.write(samples(0.75, frames: 4))
        let output = render(buffer, frames: 1)
        XCTAssertGreaterThan(output[0], 0.01, "the retained frame must be fresh, not the discarded old audio")
        XCTAssertGreaterThan(buffer.metrics().droppedFrames, 0)
    }

    func testTrimRetainsACushionAboveTarget() {
        let buffer = RemSoundPlayoutBuffer(capacityFrames: 20_000)
        buffer.reset(targetFrames: 480)
        buffer.write(samples(0.1, frames: 960))
        _ = render(buffer, frames: 120)
        for _ in 0..<12 { buffer.write(samples(0.1, frames: 960)) }
        let metrics = buffer.metrics()
        XCTAssertGreaterThan(metrics.trimEvents, 0)
        XCTAssertGreaterThan(metrics.bufferedFrames, metrics.targetFrames)
    }

    func testPartialGapIsClassifiedAsDeviceGulpWhenNearTarget() {
        let buffer = RemSoundPlayoutBuffer(capacityFrames: 2_000)
        buffer.reset(targetFrames: 480)
        buffer.write(samples(0.5, frames: 480))
        _ = render(buffer, frames: 240)
        _ = render(buffer, frames: 480)
        let metrics = buffer.metrics()
        XCTAssertEqual(metrics.underruns, 1)
        XCTAssertEqual(metrics.deviceGulpUnderruns, 1)
        XCTAssertEqual(metrics.tuneBlockingUnderruns, 0)
        XCTAssertEqual(metrics.concealedFrames, 240)
    }

    func testAutoTuneRaisesImmediatelyAndLowersWithHysteresis() {
        let raised = RemSoundLatencyAutoTune.decide(
            samples: [.init(arrivalGapMilliseconds: 120, renderGapMilliseconds: 5), .init(arrivalGapMilliseconds: 120, renderGapMilliseconds: 5)],
            frameMilliseconds: 20, currentTargetMilliseconds: 30, minimumTargetMilliseconds: 20, maximumTargetMilliseconds: 200, tuneBlockingUnderruns: 0
        )
        XCTAssertEqual(raised, .retarget(130))
        let blocked = RemSoundLatencyAutoTune.decide(
            samples: [.init(arrivalGapMilliseconds: 0, renderGapMilliseconds: 2), .init(arrivalGapMilliseconds: 0, renderGapMilliseconds: 2)],
            frameMilliseconds: 20, currentTargetMilliseconds: 100, minimumTargetMilliseconds: 20, maximumTargetMilliseconds: 200, tuneBlockingUnderruns: 1
        )
        XCTAssertEqual(blocked, .hold("producer starvation"))
    }
}
