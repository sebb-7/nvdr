import Foundation
import CoreGraphics
import XCTest
@testable import FarRelay

final class RemoteSpeechEventTests: XCTestCase {
    func testSequencerKeepsOneGenerationAndStrictSequenceOrder() {
        var sequencer = RemoteSpeechEventSequencer()

        let first = sequencer.utterance(ssml: "<speak>First</speak>")
        let cancellation = sequencer.cancellation()
        let second = sequencer.utterance(ssml: "<speak>Second</speak>")

        XCTAssertEqual([first?.sequence, cancellation?.sequence, second?.sequence], [1, 2, 3])
        XCTAssertEqual(first?.generation, cancellation?.generation)
        XCTAssertEqual(cancellation?.generation, second?.generation)
        XCTAssertEqual(cancellation?.kind, .cancel)
    }

    func testRejectsOversizeAndMalformedEvents() {
        XCTAssertNil(
            RemoteSpeechEvent(
                generation: UUID(),
                sequence: 1,
                kind: .utterance,
                ssml: String(repeating: "x", count: RemoteSpeechEvent.maximumPayloadBytes + 1)
            )
        )
        XCTAssertNil(RemoteSpeechEvent(generation: UUID(), sequence: 1, kind: .utterance))
        XCTAssertNil(
            RemoteSpeechEvent(
                generation: UUID(),
                sequence: 1,
                kind: .cancel,
                ssml: "<speak>must not be present</speak>"
            )
        )
    }

    func testSSMLTextFallbackPreservesOnlyCharacterData() {
        XCTAssertEqual(
            RemoteSpeechPlainTextExtractor.extract(from: "<speak>Hello <break time=\"1s\"/>world &amp; friends.</speak>"),
            "Hello world & friends."
        )
        XCTAssertNil(RemoteSpeechPlainTextExtractor.extract(from: "<speak>broken"))
    }

    func testPlaybackGateRejectsStaleEventsCancelsAndBoundsQueue() throws {
        let generation = UUID()
        let otherGeneration = UUID()
        var gate = RemoteSpeechPlaybackGate()
        gate.begin(generation: generation)

        let first = try XCTUnwrap(RemoteSpeechEvent(generation: generation, sequence: 1, kind: .utterance, ssml: "<speak>one</speak>"))
        XCTAssertEqual(gate.receive(first), .enqueue(first))
        XCTAssertEqual(gate.receive(first), .ignored)

        let wrongGeneration = try XCTUnwrap(RemoteSpeechEvent(generation: otherGeneration, sequence: 2, kind: .utterance, ssml: "<speak>other</speak>"))
        XCTAssertEqual(gate.receive(wrongGeneration), .ignored)

        for sequence in 2...RemoteSpeechPlaybackGate.maximumQueuedUtterances {
            let event = try XCTUnwrap(RemoteSpeechEvent(generation: generation, sequence: UInt64(sequence), kind: .utterance, ssml: "<speak>queued</speak>"))
            XCTAssertEqual(gate.receive(event), .enqueue(event))
        }
        let newest = try XCTUnwrap(RemoteSpeechEvent(generation: generation, sequence: UInt64(RemoteSpeechPlaybackGate.maximumQueuedUtterances + 1), kind: .utterance, ssml: "<speak>newest</speak>"))
        XCTAssertEqual(gate.receive(newest), .interruptAndEnqueue(newest))

        let cancel = try XCTUnwrap(RemoteSpeechEvent(generation: generation, sequence: UInt64(RemoteSpeechPlaybackGate.maximumQueuedUtterances + 2), kind: .cancel))
        XCTAssertEqual(gate.receive(cancel), .cancel)
    }

    func testQueueIsFifoAndBoundsStaleOutput() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RemoteSpeechIPC(queueURL: directory.appending(path: "events.json"))
        let generation = UUID()

        for sequence in 1...(RemoteSpeechIPC.maximumQueuedEvents + 2) {
            let event = try XCTUnwrap(
                RemoteSpeechEvent(
                    generation: generation,
                    sequence: UInt64(sequence),
                    kind: .utterance,
                    ssml: "<speak>event</speak>"
                )
            )
            XCTAssertTrue(store.append(event))
        }

        let drained = store.drain()
        XCTAssertEqual(drained.count, RemoteSpeechIPC.maximumQueuedEvents)
        XCTAssertEqual(drained.first?.sequence, 3)
        XCTAssertEqual(drained.last?.sequence, UInt64(RemoteSpeechIPC.maximumQueuedEvents + 2))
        XCTAssertTrue(store.drain().isEmpty)
    }
}

final class RemoteKeyLeaseTests: XCTestCase {
    func testLeaseRejectsOtherControllerAndStaleGeneration() throws {
        var lease = RemoteKeyLease()
        let granted = lease.requestControl("controller-a")
        guard case .granted(let generation) = granted else {
            return XCTFail("Expected control grant")
        }
        XCTAssertEqual(lease.requestControl("controller-b"), .busy)

        let key = try XCTUnwrap(RemoteKey(rawValue: 0x04))
        let stale = RemoteKeyEvent(controllerID: "controller-a", generation: generation - 1, key: key, isPressed: true)
        XCTAssertEqual(lease.accept(stale), .rejected)
    }

    func testReleaseAllReturnsModifierUpsAndInvalidatesGeneration() throws {
        var lease = RemoteKeyLease()
        guard case .granted(let generation) = lease.requestControl("controller-a") else {
            return XCTFail("Expected control grant")
        }
        let leftControl = RemoteKey.leftControl
        let rightOption = RemoteKey.rightOption
        XCTAssertEqual(
            lease.accept(RemoteKeyEvent(controllerID: "controller-a", generation: generation, key: leftControl, isPressed: true)),
            .accepted(RemoteKeyEvent(controllerID: "controller-a", generation: generation, key: leftControl, isPressed: true))
        )
        XCTAssertEqual(
            lease.accept(RemoteKeyEvent(controllerID: "controller-a", generation: generation, key: rightOption, isPressed: true)),
            .accepted(RemoteKeyEvent(controllerID: "controller-a", generation: generation, key: rightOption, isPressed: true))
        )

        let releases = lease.revoke()
        XCTAssertEqual(releases.map(\.key), [leftControl, rightOption])
        XCTAssertTrue(releases.allSatisfy { !$0.isPressed })
        XCTAssertEqual(
            lease.accept(RemoteKeyEvent(controllerID: "controller-a", generation: generation, key: leftControl, isPressed: true)),
            .rejected
        )
    }

    func testSyntheticTargetEventsAreIgnoredByCaptureMarker() {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        XCTAssertNotNil(event)
        if let event {
            FarRelaySyntheticEvent.mark(event)
            XCTAssertTrue(FarRelaySyntheticEvent.isFarRelayEvent(event))
        }
    }
}

final class MacBetaDiagnosticsTests: XCTestCase {
    func testDiagnosticReportIsSanitized() {
        let report = MacDiagnosticSnapshot(
            readiness: .fullMacRemoteReady,
            providerEmbedded: true,
            providerEventsReceived: true,
            eventCount: 17,
            lastEventAge: 0.4,
            ssmlAvailable: true,
            controllerID: "controller-with-a-secret",
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            hostSocketReady: true
        ).sanitizedReport()

        XCTAssertTrue(report.contains("Events received: 17"))
        XCTAssertTrue(report.contains("Active controller: connected"))
        XCTAssertFalse(report.contains("controller-with-a-secret"))
        XCTAssertFalse(report.contains("utterance"))
    }

    func testHostProtocolRejectsOversizeInputAndKeepsResponseMetadataOnly() {
        let oversized = String(repeating: "x", count: MacHostProtocol.maximumFrameBytes + 1)
        let response = MacHostProtocol.error(nil, code: "frame_too_large", message: oversized)
        XCTAssertTrue(response.contains("frame_too_large"))
        XCTAssertLessThan(response.utf8.count, 512)
        XCTAssertFalse(MacHostProtocol.success("request", value: ["subscribed": true]).contains("speech.utterance"))
    }
}
