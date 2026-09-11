import Foundation
import XCTest
@testable import Nvdr

final class SSHPTYTransportTests: XCTestCase {
    func testDefaultConfiguration() throws {
        let configuration = try SSHPTYConfiguration()
        let expectedDimensions = try SSHPTYDimensions(columns: 80, rows: 24)

        XCTAssertEqual(configuration.terminalType, "xterm-256color")
        XCTAssertEqual(configuration.dimensions, expectedDimensions)
    }

    func testConfigurationRejectsInvalidValues() {
        XCTAssertThrowsError(try SSHPTYConfiguration(terminalType: "   "))
        XCTAssertThrowsError(try SSHPTYConfiguration(columns: 0))
        XCTAssertThrowsError(try SSHPTYConfiguration(rows: 0))
        XCTAssertThrowsError(try SSHPTYConfiguration(pixelWidth: -1))
        XCTAssertThrowsError(try SSHPTYConfiguration(pixelHeight: -1))
    }

    func testTransportPreservesExactInputOutputAndResizeBytes() async throws {
        let recorder = PTYRecorder()
        let (stream, continuation) = AsyncThrowingStream<SSHPTYEvent, Error>.makeStream()
        let lifetime = SSHPTYTransportLifetime()
        let transport = SSHPTYTransport(
            eventSequence: SSHPTYEventSequence(testStream: stream),
            lifetime: lifetime,
            writeBytes: { data in await recorder.recordInput(data) },
            changeSize: { dimensions in await recorder.recordResize(dimensions) }
        )
        let output = Data([0x1B, 0x5B, 0x44, 0xC3, 0xA9])
        continuation.yield(.stdout(output))
        continuation.finish()

        let input = Data([0x03, 0x1B, 0x5B, 0x41, 0xF0, 0x9F, 0x98, 0x80])
        let expectedResize = try SSHPTYDimensions(
            columns: 120,
            rows: 40,
            pixelWidth: 960,
            pixelHeight: 640
        )
        try await transport.write(input)
        try await transport.resize(columns: 120, rows: 40, pixelWidth: 960, pixelHeight: 640)

        var iterator = transport.events().makeAsyncIterator()
        XCTAssertEqual(try await iterator.next(), .stdout(output))
        XCTAssertNil(try await iterator.next())
        let recordedInputs = await recorder.inputs()
        let recordedResizes = await recorder.resizes()
        XCTAssertEqual(recordedInputs, [input])
        XCTAssertEqual(recordedResizes, [expectedResize])
    }

    func testClosedTransportRejectsStaleWritesAndResizes() async throws {
        let (stream, continuation) = AsyncThrowingStream<SSHPTYEvent, Error>.makeStream()
        continuation.finish()
        let lifetime = SSHPTYTransportLifetime()
        let transport = SSHPTYTransport(
            eventSequence: SSHPTYEventSequence(testStream: stream),
            lifetime: lifetime,
            writeBytes: { _ in },
            changeSize: { _ in }
        )
        await lifetime.invalidate()

        do {
            try await transport.write(Data())
            XCTFail("Expected stale PTY write to fail")
        } catch let error as SSHPTYConfigurationError {
            XCTAssertEqual(error, .closedTransport)
        }
        do {
            try await transport.resize(columns: 80, rows: 24)
            XCTFail("Expected stale PTY resize to fail")
        } catch let error as SSHPTYConfigurationError {
            XCTAssertEqual(error, .closedTransport)
        }
    }
}

private actor PTYRecorder {
    private var recordedInputs: [Data] = []
    private var recordedResizes: [SSHPTYDimensions] = []

    func recordInput(_ data: Data) {
        recordedInputs.append(data)
    }

    func recordResize(_ dimensions: SSHPTYDimensions) {
        recordedResizes.append(dimensions)
    }

    func inputs() -> [Data] { recordedInputs }
    func resizes() -> [SSHPTYDimensions] { recordedResizes }
}
