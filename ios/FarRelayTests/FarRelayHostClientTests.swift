import Foundation
import XCTest
@testable import FarRelay

final class FarRelayHostClientTests: XCTestCase {
    func testEncodesV1OperationsAndDecodesTypedResults() async throws {
        let transport = FakeHostTransport()
        let client = FarRelayHostClient(transport: transport)

        let capabilitiesTask = Task { try await client.capabilities() }
        let capabilitiesRequest = try await nextRequest(from: transport)
        XCTAssertEqual(capabilitiesRequest.version, 1)
        XCTAssertEqual(capabilitiesRequest.operation, "capabilities")
        XCTAssertNotNil(capabilitiesRequest.requestID)
        transport.sendSuccess(
            requestID: capabilitiesRequest.requestID,
            result: capabilitiesResult()
        )
        let capabilities = try await capabilitiesTask.value
        XCTAssertEqual(capabilities, capabilitiesResult())

        let infoTask = Task { try await client.hostInfo() }
        let infoRequest = try await nextRequest(from: transport)
        XCTAssertEqual(infoRequest.operation, "host.info")
        transport.sendSuccess(requestID: infoRequest.requestID, result: hostInfoResult())
        let info = try await infoTask.value
        XCTAssertEqual(info, hostInfoResult())

        let processesTask = Task { try await client.processes() }
        let processesRequest = try await nextRequest(from: transport)
        XCTAssertEqual(processesRequest.operation, "process.list")
        transport.sendSuccess(requestID: processesRequest.requestID, result: [processResult()])
        let processes = try await processesTask.value
        XCTAssertEqual(processes, [processResult()])

        let processTask = Task { try await client.processInfo(pid: 42) }
        let processRequest = try await nextRequest(from: transport)
        XCTAssertEqual(processRequest.operation, "process.info")
        XCTAssertEqual(processRequest.pid, 42)
        transport.sendSuccess(requestID: processRequest.requestID, result: processResult())
        let process = try await processTask.value
        XCTAssertEqual(process, processResult())
    }

    func testFramesSplitChunksIncludingSplitUTF8() async throws {
        let transport = FakeHostTransport()
        let client = FarRelayHostClient(transport: transport)
        let task = Task { try await client.hostInfo() }
        let request = try await nextRequest(from: transport)
        let response = try successData(requestID: request.requestID, result: hostInfoResult(hostname: "café"))
        let split = try XCTUnwrap(response.firstIndex(of: 0xC3))

        XCTAssertGreaterThan(response.count, split)
        for byte in response {
            transport.sendStdout(Data([byte]))
        }

        let info = try await task.value
        XCTAssertEqual(info.hostname, "café")
    }

    func testCorrelatesManyResponsesInOneChunkOutOfOrder() async throws {
        let transport = FakeHostTransport()
        let client = FarRelayHostClient(transport: transport)
        let capabilitiesTask = Task { try await client.capabilities() }
        let processesTask = Task { try await client.processes() }
        let first = try await nextRequest(from: transport)
        let second = try await nextRequest(from: transport)
        let requests = [first, second]
        let capabilitiesRequest = try XCTUnwrap(requests.first { $0.operation == "capabilities" })
        let processesRequest = try XCTUnwrap(requests.first { $0.operation == "process.list" })
        let responses = try successData(requestID: processesRequest.requestID, result: [processResult()])
            + successData(requestID: capabilitiesRequest.requestID, result: capabilitiesResult())

        transport.sendStdout(responses)

        let capabilities = try await capabilitiesTask.value
        let processes = try await processesTask.value
        XCTAssertEqual(capabilities, capabilitiesResult())
        XCTAssertEqual(processes, [processResult()])
    }

    func testSurfacesStructuredHostErrors() async throws {
        let transport = FakeHostTransport()
        let client = FarRelayHostClient(transport: transport)
        let task = Task { try await client.processInfo(pid: 999) }
        let request = try await nextRequest(from: transport)
        transport.sendError(
            requestID: request.requestID,
            code: "process_not_found",
            message: "process 999 was not found"
        )

        await assertError(task, equals: .hostError(
            code: "process_not_found",
            message: "process 999 was not found"
        ))
    }

    func testRejectsMissingRequestID() async throws {
        let transport = FakeHostTransport()
        let client = FarRelayHostClient(transport: transport)
        let task = Task { try await client.capabilities() }
        _ = try await nextRequest(from: transport)

        transport.sendStdout(Data(#"{"version":1,"ok":true,"result":{}}"#.utf8) + Data([0x0A]))

        await assertError(task, equals: .missingRequestID)
    }

    func testRejectsUnexpectedRequestIDAndUnsupportedVersion() async throws {
        let unexpectedTransport = FakeHostTransport()
        let unexpectedClient = FarRelayHostClient(transport: unexpectedTransport)
        let unexpectedTask = Task { try await unexpectedClient.capabilities() }
        _ = try await nextRequest(from: unexpectedTransport)
        unexpectedTransport.sendSuccess(requestID: "someone-else", result: capabilitiesResult())
        await assertError(unexpectedTask, equals: .unexpectedRequestID("someone-else"))

        let versionTransport = FakeHostTransport()
        let versionClient = FarRelayHostClient(transport: versionTransport)
        let versionTask = Task { try await versionClient.capabilities() }
        let request = try await nextRequest(from: versionTransport)
        versionTransport.sendStdout(try responseData(
            version: 2,
            requestID: request.requestID,
            ok: true,
            result: capabilitiesResult(),
            error: nil
        ))
        await assertError(versionTask, equals: .unsupportedProtocolVersion(2))
    }

    func testMalformedLineDoesNotPreventLaterValidRequest() async throws {
        let transport = FakeHostTransport()
        let client = FarRelayHostClient(transport: transport)
        let malformedTask = Task { try await client.capabilities() }
        _ = try await nextRequest(from: transport)
        transport.sendStdout(Data("not json\n".utf8))
        await assertMalformedResponse(malformedTask)

        let validTask = Task { try await client.capabilities() }
        let validRequest = try await nextRequest(from: transport)
        transport.sendSuccess(requestID: validRequest.requestID, result: capabilitiesResult())
        let capabilities = try await validTask.value
        XCTAssertEqual(capabilities, capabilitiesResult())
    }

    func testEOFFailsPendingRequestsAndLaterRequests() async throws {
        let transport = FakeHostTransport()
        let client = FarRelayHostClient(transport: transport)
        let task = Task { try await client.capabilities() }
        _ = try await nextRequest(from: transport)
        transport.sendStdout(Data("{\"version\":1".utf8))
        transport.finish()

        await assertError(task, equals: .unexpectedEOF)
        do {
            _ = try await client.capabilities()
            XCTFail("Expected a closed HostClient to reject a new request")
        } catch let error as HostClientError {
            XCTAssertEqual(error, .unexpectedEOF)
        }
    }

    func testMissingSuccessfulResultAndCloseFailPendingRequests() async throws {
        let resultTransport = FakeHostTransport()
        let resultClient = FarRelayHostClient(transport: resultTransport)
        let resultTask = Task { try await resultClient.capabilities() }
        let resultRequest = try await nextRequest(from: resultTransport)
        resultTransport.sendStdout(try responseData(
            version: 1,
            requestID: resultRequest.requestID,
            ok: true,
            result: Optional<EmptyResult>.none,
            error: nil
        ))
        await assertError(resultTask, equals: .missingResult)

        let closeTransport = FakeHostTransport()
        let closeClient = FarRelayHostClient(transport: closeTransport)
        let closeTask = Task { try await closeClient.capabilities() }
        _ = try await nextRequest(from: closeTransport)
        await closeClient.close()
        await assertError(closeTask, equals: .connectionClosed)
    }

    func testCancellationRemovesPendingRequest() async throws {
        let transport = FakeHostTransport()
        let client = FarRelayHostClient(transport: transport)
        let task = Task { try await client.capabilities() }
        _ = try await nextRequest(from: transport)

        task.cancel()

        await assertError(task, equals: .cancelled)
    }

    func testEncodesVoiceOverStatusMovePressAndDecodesState() async throws {
        let transport = FakeHostTransport()
        let client = FarRelayHostClient(transport: transport)

        let statusTask = Task { try await client.voiceOverStatus() }
        let statusRequest = try await nextRequest(from: transport)
        XCTAssertEqual(statusRequest.version, 1)
        XCTAssertEqual(statusRequest.operation, "voiceover.status")
        XCTAssertNotNil(statusRequest.requestID)
        transport.sendSuccess(requestID: statusRequest.requestID, result: voiceOverStatusResult())
        let status = try await statusTask.value
        XCTAssertEqual(status, voiceOverStatusResult())

        let directions: [VoiceOverMoveDirection] = [.left, .right, .up, .down, .into, .out]
        for direction in directions {
            let moveTask = Task { try await client.voiceOverMove(direction) }
            let moveRequest = try await nextRequest(from: transport)
            XCTAssertEqual(moveRequest.operation, "voiceover.move")
            XCTAssertEqual(moveRequest.direction, direction.rawValue)
            XCTAssertNil(moveRequest.script)
            transport.sendSuccess(
                requestID: moveRequest.requestID,
                result: VoiceOverMoveResult(moved: true)
            )
            let moved = try await moveTask.value
            XCTAssertEqual(moved, VoiceOverMoveResult(moved: true))
        }

        let pressTask = Task { try await client.voiceOverPress() }
        let pressRequest = try await nextRequest(from: transport)
        XCTAssertEqual(pressRequest.operation, "voiceover.press")
        XCTAssertNil(pressRequest.script)
        transport.sendSuccess(
            requestID: pressRequest.requestID,
            result: VoiceOverPressResult(pressed: true)
        )
        let pressed = try await pressTask.value
        XCTAssertEqual(pressed, VoiceOverPressResult(pressed: true))

        let stateTask = Task { try await client.voiceOverState() }
        let stateRequest = try await nextRequest(from: transport)
        XCTAssertEqual(stateRequest.operation, "voiceover.state")
        transport.sendSuccess(requestID: stateRequest.requestID, result: voiceOverStateResult())
        let state = try await stateTask.value
        XCTAssertEqual(state, voiceOverStateResult())
    }

    func testVoiceOverHostErrorsPreserveRequestIDCorrelation() async throws {
        let transport = FakeHostTransport()
        let client = FarRelayHostClient(transport: transport)
        let task = Task { try await client.voiceOverMove(.right) }
        let request = try await nextRequest(from: transport)
        XCTAssertEqual(request.operation, "voiceover.move")
        XCTAssertEqual(request.direction, "right")
        transport.sendError(
            requestID: request.requestID,
            code: "voiceover_control_unavailable",
            message: "VoiceOver AppleScript control is not currently usable"
        )
        await assertError(task, equals: .hostError(
            code: "voiceover_control_unavailable",
            message: "VoiceOver AppleScript control is not currently usable"
        ))
    }

    func testVoiceOverUnsupportedOperationIsStructured() async throws {
        let transport = FakeHostTransport()
        let client = FarRelayHostClient(transport: transport)
        let task = Task { try await client.voiceOverStatus() }
        let request = try await nextRequest(from: transport)
        transport.sendError(
            requestID: request.requestID,
            code: "unsupported_operation",
            message: "unsupported operation: voiceover.status"
        )
        await assertError(task, equals: .hostError(
            code: "unsupported_operation",
            message: "unsupported operation: voiceover.status"
        ))
    }

    func testWriteFailureIsStructured() async throws {
        let transport = FakeHostTransport(writeFailure: FakeHostTransportError.writeFailed)
        let client = FarRelayHostClient(transport: transport)

        do {
            _ = try await client.capabilities()
            XCTFail("Expected write failure")
        } catch let error as HostClientError {
            guard case .writeFailed = error else {
                return XCTFail("Expected write failure, got \(error)")
            }
        }
    }

    func testStderrIsBoundedDiagnosticsAndNeverProtocolData() async throws {
        let transport = FakeHostTransport()
        let client = FarRelayHostClient(transport: transport)
        for value in 0..<55 {
            transport.sendStderr(Data("diagnostic \(value)\n".utf8))
        }

        let task = Task { try await client.capabilities() }
        let request = try await nextRequest(from: transport)
        transport.sendSuccess(requestID: request.requestID, result: capabilitiesResult())
        _ = try await task.value

        let diagnostics = await client.recentDiagnostics()
        XCTAssertEqual(diagnostics.count, 50)
        XCTAssertEqual(diagnostics.first, "diagnostic 5")
        XCTAssertEqual(diagnostics.last, "diagnostic 54")
    }

    func testResolvedHostCommandUsesProfileValueWithoutConcatenatingArguments() {
        XCTAssertEqual(FarRelayHostConnection.defaultCommand, "farrelay-host")
        XCTAssertEqual(FarRelayHostConnection.command, "farrelay-host")
        XCTAssertEqual(FarRelayHostConnection.resolvedCommand(""), "farrelay-host")
        XCTAssertEqual(FarRelayHostConnection.resolvedCommand("   "), "farrelay-host")
        XCTAssertEqual(FarRelayHostConnection.resolvedCommand("/usr/local/bin/farrelay-host"), "/usr/local/bin/farrelay-host")
    }

    func testWaitUntilUnavailableCompletesAfterClose() async {
        let transport = FakeHostTransport()
        let client = FarRelayHostClient(transport: transport)
        let waiter = Task { await client.waitUntilUnavailable() }
        await client.close()
        await waiter.value
        await client.waitUntilUnavailable()
    }

    private func nextRequest(from transport: FakeHostTransport) async throws -> WireRequest {
        let data = await transport.nextWrite()
        XCTAssertEqual(data.last, 0x0A)
        return try JSONDecoder().decode(WireRequest.self, from: Data(data.dropLast()))
    }

    private func capabilitiesResult() -> HostCapabilities {
        HostCapabilities(
            protocolVersion: 1,
            hostImplementation: "farrelay-host",
            hostVersion: "0.1.0",
            operations: ["host.info", "process.list", "process.info"]
        )
    }

    private func hostInfoResult(hostname: String? = "relay") -> HostInfo {
        HostInfo(
            osFamily: "linux",
            osVersion: "ExampleOS 1",
            architecture: "x86_64",
            hostname: hostname,
            implementation: "farrelay-host",
            version: "0.1.0"
        )
    }

    private func processResult() -> HostProcessInfo {
        HostProcessInfo(pid: 42, name: "relay", status: .unknown)
    }

    private func voiceOverStatusResult() -> VoiceOverStatus {
        VoiceOverStatus(
            platformSupported: true,
            available: true,
            voiceOverRunning: true,
            appleScriptBridgeUsable: true,
            message: nil
        )
    }

    private func voiceOverStateResult() -> VoiceOverState {
        VoiceOverState(
            lastSpokenPhrase: "Mail, button",
            voiceOverCursorText: nil,
            keyboardCursorText: "Inbox"
        )
    }

    private func successData<Result: Encodable>(requestID: String, result: Result) throws -> Data {
        try responseData(version: 1, requestID: requestID, ok: true, result: result, error: nil)
    }

    private func responseData<Result: Encodable>(
        version: Int,
        requestID: String?,
        ok: Bool,
        result: Result?,
        error: WireError?
    ) throws -> Data {
        try JSONEncoder().encode(WireResponse(
            version: version,
            requestID: requestID,
            ok: ok,
            result: result,
            error: error
        )) + Data([0x0A])
    }

    private func assertError<Result>(
        _ task: Task<Result, Error>,
        equals expected: HostClientError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected HostClientError", file: file, line: line)
        } catch let error as HostClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected HostClientError, got \(error)", file: file, line: line)
        }
    }

    private func assertMalformedResponse<Result>(
        _ task: Task<Result, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected malformed response", file: file, line: line)
        } catch let error as HostClientError {
            guard case .malformedResponse = error else {
                return XCTFail("Expected malformed response, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Expected HostClientError, got \(error)", file: file, line: line)
        }
    }
}

private final class FakeHostTransport: HostByteTransport, @unchecked Sendable {
    private let stream: AsyncThrowingStream<HostTransportEvent, Error>
    private let continuation: AsyncThrowingStream<HostTransportEvent, Error>.Continuation
    private let writes = HostWriteRecorder()
    private let writeFailure: Error?

    init(writeFailure: Error? = nil) {
        let pair = AsyncThrowingStream<HostTransportEvent, Error>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        self.writeFailure = writeFailure
    }

    func hostEvents() -> AsyncThrowingStream<HostTransportEvent, Error> {
        stream
    }

    func write(_ data: Data) async throws {
        if let writeFailure {
            throw writeFailure
        }
        await writes.record(data)
    }

    func nextWrite() async -> Data {
        await writes.next()
    }

    func sendStdout(_ data: Data) {
        continuation.yield(.stdout(data))
    }

    func sendStderr(_ data: Data) {
        continuation.yield(.stderr(data))
    }

    func sendSuccess<Result: Encodable>(requestID: String, result: Result) {
        let data = try! JSONEncoder().encode(WireResponse(
            version: 1,
            requestID: requestID,
            ok: true,
            result: result,
            error: nil
        )) + Data([0x0A])
        sendStdout(data)
    }

    func sendError(requestID: String, code: String, message: String) {
        let data = try! JSONEncoder().encode(WireResponse<EmptyResult>(
            version: 1,
            requestID: requestID,
            ok: false,
            result: nil,
            error: WireError(code: code, message: message)
        )) + Data([0x0A])
        sendStdout(data)
    }

    func finish() {
        continuation.finish()
    }
}

private actor HostWriteRecorder {
    private var values: [Data] = []
    private var waiters: [CheckedContinuation<Data, Never>] = []

    func record(_ data: Data) {
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: data)
        } else {
            values.append(data)
        }
    }

    func next() async -> Data {
        if !values.isEmpty {
            return values.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private struct WireRequest: Decodable {
    let version: Int
    let requestID: String
    let operation: String
    let params: WireParameters?

    var pid: UInt32? { params?.pid }
    var direction: String? { params?.direction }
    var script: String? { params?.script }

    enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case operation
        case params
    }
}

private struct WireParameters: Decodable {
    let pid: UInt32?
    let direction: String?
    let script: String?
}

private struct WireResponse<Result: Encodable>: Encodable {
    let version: Int
    let requestID: String?
    let ok: Bool
    let result: Result?
    let error: WireError?

    enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case ok
        case result
        case error
    }
}

private struct WireError: Encodable {
    let code: String
    let message: String
}

private struct EmptyResult: Encodable {}

private enum FakeHostTransportError: LocalizedError, Sendable {
    case writeFailed

    var errorDescription: String? {
        "Fake host transport write failed."
    }
}
