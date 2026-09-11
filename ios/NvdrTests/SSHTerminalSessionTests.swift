import Foundation
import XCTest
@testable import Nvdr

@MainActor
final class SSHTerminalSessionTests: XCTestCase {
    func testIncomingChunksReachTerminalInOrderAndSplitUTF8RemainsCorrect() async {
        let transport = FakePTYTransport(events: [
            .stdout(Data("first ".utf8)),
            .stdout(Data([0xC3])),
            .stdout(Data([0xA9])),
            .stderr(Data(" second".utf8))
        ])
        let session = SSHTerminalSession(transport: transport)

        session.start()
        let state = await session.waitForCompletion()

        XCTAssertEqual(state, .ended)
        XCTAssertTrue(renderedText(session.snapshot()).contains("first é second"))
    }

    func testInputAndResizeReachTheirOwners() async throws {
        let transport = FakePTYTransport(blockBeforeEvents: true)
        let session = SSHTerminalSession(transport: transport)
        let input = Data([0x03, 0x1B, 0x5B, 0x41, 0xC3, 0xA9])
        let expectedDimensions = try SSHPTYDimensions(
            columns: 120,
            rows: 40,
            pixelWidth: 960,
            pixelHeight: 640
        )

        session.start()
        await waitUntil { await transport.hasStartedReading() }
        try await session.send(input)
        try await session.resize(columns: 120, rows: 40, pixelWidth: 960, pixelHeight: 640)

        let recordedInputs = await transport.inputs()
        let recordedResizes = await transport.resizes()
        XCTAssertEqual(recordedInputs, [input])
        XCTAssertEqual(recordedResizes, [expectedDimensions])
        XCTAssertEqual(session.snapshot().dimensions, TerminalDimensions(columns: 120, rows: 40))

        session.close()
        await transport.releaseReadLoop()
        await waitUntil { await transport.observedCancellation() }
    }

    func testEOFTerminatesCleanly() async {
        let session = SSHTerminalSession(transport: FakePTYTransport())

        session.start()

        let state = await session.waitForCompletion()
        XCTAssertEqual(state, .ended)
    }

    func testTransportFailureBecomesObservableState() async {
        let session = SSHTerminalSession(transport: FakePTYTransport(failsAfterEvents: true))

        session.start()

        let state = await session.waitForCompletion()
        XCTAssertEqual(state, .failed("Fake PTY read failure."))
    }

    func testCloseCancelsReadLoopIsIdempotentAndRejectsLateBytes() async {
        let transport = FakePTYTransport(
            events: [.stdout(Data("late terminal bytes".utf8))],
            blockBeforeEvents: true
        )
        let session = SSHTerminalSession(transport: transport)

        session.start()
        await waitUntil { await transport.hasStartedReading() }
        let revisionBeforeClose = session.snapshot().revision

        session.close()
        session.close()
        await transport.releaseReadLoop()
        await waitUntil { await transport.observedCancellation() }

        XCTAssertEqual(session.state, .closed)
        XCTAssertEqual(session.snapshot().revision, revisionBeforeClose)
        XCTAssertFalse(renderedText(session.snapshot()).contains("late terminal bytes"))
    }

    func testDeallocationCancelsReadLoop() async {
        let transport = FakePTYTransport(blockBeforeEvents: true)
        var session: SSHTerminalSession? = SSHTerminalSession(transport: transport)

        session?.start()
        await waitUntil { await transport.hasStartedReading() }
        session = nil
        await transport.releaseReadLoop()

        await waitUntil { await transport.observedCancellation() }
    }

    private func renderedText(_ snapshot: TerminalSnapshot) -> String {
        (snapshot.scrollback + snapshot.viewport).map(\.text).joined(separator: "\n")
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private actor FakePTYTransport: SSHPTYTransporting {
    private let events: [SSHPTYEvent]
    private let blockBeforeEvents: Bool
    private let failsAfterEvents: Bool
    private var recordedInputs: [Data] = []
    private var recordedResizes: [SSHPTYDimensions] = []
    private var startedReading = false
    private var cancellationObserved = false
    private var readLoopContinuation: CheckedContinuation<Void, Never>?

    init(
        events: [SSHPTYEvent] = [],
        blockBeforeEvents: Bool = false,
        failsAfterEvents: Bool = false
    ) {
        self.events = events
        self.blockBeforeEvents = blockBeforeEvents
        self.failsAfterEvents = failsAfterEvents
    }

    func consumeEvents(
        _ handler: @escaping @Sendable (SSHPTYEvent) async throws -> Void
    ) async throws {
        startedReading = true
        do {
            if blockBeforeEvents {
                await withCheckedContinuation { continuation in
                    readLoopContinuation = continuation
                }
            }
            for event in events {
                try await handler(event)
            }
            if failsAfterEvents {
                throw FakePTYTransportError.readFailed
            }
        } catch is CancellationError {
            cancellationObserved = true
            throw CancellationError()
        }
    }

    func write(_ data: Data) {
        recordedInputs.append(data)
    }

    func resize(
        columns: Int,
        rows: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws {
        recordedResizes.append(
            try SSHPTYDimensions(
                columns: columns,
                rows: rows,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        )
    }

    func inputs() -> [Data] { recordedInputs }
    func resizes() -> [SSHPTYDimensions] { recordedResizes }
    func hasStartedReading() -> Bool { startedReading }
    func observedCancellation() -> Bool { cancellationObserved }

    func releaseReadLoop() {
        let continuation = readLoopContinuation
        readLoopContinuation = nil
        continuation?.resume()
    }
}

private enum FakePTYTransportError: LocalizedError, Sendable {
    case readFailed

    var errorDescription: String? {
        switch self {
        case .readFailed:
            "Fake PTY read failure."
        }
    }
}
