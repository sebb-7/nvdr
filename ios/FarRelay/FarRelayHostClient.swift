import Foundation

/// The stable v1 capabilities returned by `farrelay-host`.
struct HostCapabilities: Codable, Sendable, Equatable {
    let protocolVersion: Int
    let hostImplementation: String
    let hostVersion: String
    let operations: [String]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case hostImplementation = "host_implementation"
        case hostVersion = "host_version"
        case operations
    }
}

/// Immutable details about the remote host.
struct HostInfo: Codable, Sendable, Equatable {
    let osFamily: String
    let osVersion: String?
    let architecture: String
    let hostname: String?
    let implementation: String
    let version: String

    enum CodingKeys: String, CodingKey {
        case osFamily = "os_family"
        case osVersion = "os_version"
        case architecture
        case hostname
        case implementation
        case version
    }
}

/// A process status represented without losing forward-compatible values.
struct HostProcessStatus: RawRepresentable, Codable, Sendable, Equatable {
    let rawValue: String

    static let running = Self(rawValue: "running")
    static let sleeping = Self(rawValue: "sleeping")
    static let stopped = Self(rawValue: "stopped")
    static let zombie = Self(rawValue: "zombie")
    static let unknown = Self(rawValue: "unknown")

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A process returned by the typed `farrelay-host` API.
struct HostProcessInfo: Codable, Sendable, Equatable {
    let pid: UInt32
    let name: String
    let status: HostProcessStatus?
}

/// Strict VoiceOver cursor movement values accepted by `voiceover.move`.
enum VoiceOverMoveDirection: String, Codable, Sendable, Equatable {
    case left
    case right
    case up
    case down
    case into
    case out
}

/// Structured `voiceover.status` result. Availability is runtime state, not capability advertisement.
struct VoiceOverStatus: Codable, Sendable, Equatable {
    let platformSupported: Bool
    let available: Bool
    let voiceOverRunning: Bool
    let appleScriptBridgeUsable: Bool
    let message: String?

    enum CodingKeys: String, CodingKey {
        case platformSupported = "platform_supported"
        case available
        case voiceOverRunning = "voiceover_running"
        case appleScriptBridgeUsable = "applescript_bridge_usable"
        case message
    }
}

/// Structured `voiceover.move` result.
struct VoiceOverMoveResult: Codable, Sendable, Equatable {
    let moved: Bool
}

/// Structured `voiceover.press` result.
struct VoiceOverPressResult: Codable, Sendable, Equatable {
    let pressed: Bool
}

/// Public VoiceOver feedback. Missing fields are omitted rather than invented.
struct VoiceOverState: Codable, Sendable, Equatable {
    let lastSpokenPhrase: String?
    let voiceOverCursorText: String?
    let keyboardCursorText: String?

    enum CodingKeys: String, CodingKey {
        case lastSpokenPhrase = "last_spoken_phrase"
        case voiceOverCursorText = "voiceover_cursor_text"
        case keyboardCursorText = "keyboard_cursor_text"
    }
}

/// The narrow, typed Apple-facing API for the FarRelay Host v1 protocol.
protocol HostClientProtocol: Sendable {
    func capabilities() async throws -> HostCapabilities
    func hostInfo() async throws -> HostInfo
    func processes() async throws -> [HostProcessInfo]
    func processInfo(pid: UInt32) async throws -> HostProcessInfo
    func voiceOverStatus() async throws -> VoiceOverStatus
    func voiceOverMove(_ direction: VoiceOverMoveDirection) async throws -> VoiceOverMoveResult
    func voiceOverPress() async throws -> VoiceOverPressResult
    func voiceOverState() async throws -> VoiceOverState
}

/// Errors produced while framing, validating, or correlating Host v1 messages.
enum HostClientError: Error, LocalizedError, Sendable, Equatable {
    case connectionClosed
    case unsupportedProtocolVersion(Int)
    case malformedResponse(String)
    case missingRequestID
    case unexpectedRequestID(String)
    case hostError(code: String, message: String)
    case missingResult
    case writeFailed(String)
    case unexpectedEOF
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectionClosed:
            return "The FarRelay Host connection closed."
        case .unsupportedProtocolVersion(let version):
            return "FarRelay Host protocol version \(version) is not supported."
        case .malformedResponse(let detail):
            return "FarRelay Host returned a malformed response: \(detail)"
        case .missingRequestID:
            return "FarRelay Host returned a response without a request ID."
        case .unexpectedRequestID(let requestID):
            return "FarRelay Host returned an unexpected request ID: \(requestID)."
        case .hostError(let code, let message):
            return "FarRelay Host error \(code): \(message)"
        case .missingResult:
            return "FarRelay Host returned a successful response without a result."
        case .writeFailed(let detail):
            return "Could not write to FarRelay Host: \(detail)"
        case .unexpectedEOF:
            return "FarRelay Host closed with an incomplete response."
        case .cancelled:
            return "The FarRelay Host request was cancelled."
        }
    }
}

/// An app-neutral byte transport used to keep Host protocol code above SSH.
protocol HostByteTransport: Sendable {
    func hostEvents() -> AsyncThrowingStream<HostTransportEvent, Error>
    func write(_ data: Data) async throws
}

enum HostTransportEvent: Sendable {
    case stdout(Data)
    case stderr(Data)
}

extension SSHExecTransport: HostByteTransport {
    func hostEvents() -> AsyncThrowingStream<HostTransportEvent, Error> {
        let source = events()
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in source {
                        switch event {
                        case .stdout(let data):
                            continuation.yield(.stdout(data))
                        case .stderr(let data):
                            continuation.yield(.stderr(data))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// One long-lived, line-framed v1 client over a generic byte transport.
actor FarRelayHostClient: HostClientProtocol {
    static let protocolVersion = 1

    private let transport: any HostByteTransport
    private var readerTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var diagnostics: [String] = []
    private var terminalError: HostClientError?

    init(transport: any HostByteTransport) {
        self.transport = transport
    }

    deinit {
        readerTask?.cancel()
    }

    func capabilities() async throws -> HostCapabilities {
        try await request(operation: "capabilities", parameters: HostEmptyParameters())
    }

    func hostInfo() async throws -> HostInfo {
        try await request(operation: "host.info", parameters: HostEmptyParameters())
    }

    func processes() async throws -> [HostProcessInfo] {
        try await request(operation: "process.list", parameters: HostEmptyParameters())
    }

    func processInfo(pid: UInt32) async throws -> HostProcessInfo {
        try await request(operation: "process.info", parameters: HostProcessInfoParameters(pid: pid))
    }

    func voiceOverStatus() async throws -> VoiceOverStatus {
        try await request(operation: "voiceover.status", parameters: HostEmptyParameters())
    }

    func voiceOverMove(_ direction: VoiceOverMoveDirection) async throws -> VoiceOverMoveResult {
        try await request(operation: "voiceover.move", parameters: HostVoiceOverMoveParameters(direction: direction))
    }

    func voiceOverPress() async throws -> VoiceOverPressResult {
        try await request(operation: "voiceover.press", parameters: HostEmptyParameters())
    }

    func voiceOverState() async throws -> VoiceOverState {
        try await request(operation: "voiceover.state", parameters: HostEmptyParameters())
    }

    /// Starts the reader before a caller begins a long-lived operation.
    func start() {
        startReaderIfNeeded()
    }

    /// Cancels local reads and fails all requests still awaiting a response.
    func close() {
        readerTask?.cancel()
        readerTask = nil
        finish(with: .connectionClosed)
    }

    /// Stderr is retained strictly as diagnostics and is never parsed as API data.
    func recentDiagnostics() -> [String] {
        diagnostics
    }

    private func request<Parameters: Encodable & Sendable, Result: Decodable & Sendable>(
        operation: String,
        parameters: Parameters
    ) async throws -> Result {
        startReaderIfNeeded()
        try Task.checkCancellation()
        if let terminalError {
            throw terminalError
        }

        let requestID = UUID().uuidString.lowercased()
        let encodedRequest: Data
        do {
            encodedRequest = try JSONEncoder().encode(
                HostRequest(
                    version: Self.protocolVersion,
                    requestID: requestID,
                    operation: operation,
                    params: parameters
                )
            ) + Data([0x0A])
        } catch {
            throw HostClientError.malformedResponse("could not encode request: \(error.localizedDescription)")
        }

        let responseData = try await awaitResponse(
            requestID: requestID,
            encodedRequest: encodedRequest
        )
        let response: HostResponse<Result>
        do {
            response = try JSONDecoder().decode(HostResponse<Result>.self, from: responseData)
        } catch {
            throw HostClientError.malformedResponse(error.localizedDescription)
        }
        guard response.version == Self.protocolVersion else {
            throw HostClientError.unsupportedProtocolVersion(response.version)
        }
        guard response.requestID == requestID else {
            throw HostClientError.unexpectedRequestID(response.requestID ?? "<missing>")
        }
        if !response.ok {
            guard let error = response.error else {
                throw HostClientError.malformedResponse("failed response without an error object")
            }
            throw HostClientError.hostError(code: error.code, message: error.message)
        }
        guard let result = response.result else {
            throw HostClientError.missingResult
        }
        return result
    }

    private func awaitResponse(requestID: String, encodedRequest: Data) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending[requestID] = continuation
                Task { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: HostClientError.connectionClosed)
                        return
                    }
                    do {
                        try await self.transport.write(encodedRequest)
                    } catch {
                        await self.failRequest(
                            requestID,
                            with: .writeFailed(error.localizedDescription)
                        )
                    }
                }
            }
        }, onCancel: {
            Task { [weak self] in
                await self?.failRequest(requestID, with: .cancelled)
            }
        })
    }

    private func startReaderIfNeeded() {
        guard readerTask == nil else { return }
        readerTask = Task { [weak self] in
            await self?.readEvents()
        }
    }

    private func readEvents() async {
        do {
            for try await event in transport.hostEvents() {
                if Task.isCancelled {
                    finish(with: .cancelled)
                    return
                }
                switch event {
                case .stdout(let data):
                    processStdout(data)
                case .stderr(let data):
                    processStderr(data)
                }
            }
            finish(with: stdoutBuffer.isEmpty ? .connectionClosed : .unexpectedEOF)
        } catch is CancellationError {
            finish(with: .cancelled)
        } catch {
            finish(with: .connectionClosed)
        }
    }

    private func processStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            var line = Data(stdoutBuffer.prefix(upTo: newline))
            stdoutBuffer.removeSubrange(...newline)
            if line.last == 0x0D {
                line.removeLast()
            }
            guard !line.isEmpty else {
                failAll(with: .malformedResponse("empty stdout line"))
                continue
            }
            processResponseLine(line)
        }
    }

    private func processResponseLine(_ line: Data) {
        let response: HostResponseHeader
        do {
            response = try JSONDecoder().decode(HostResponseHeader.self, from: line)
        } catch {
            failAll(with: .malformedResponse(error.localizedDescription))
            return
        }
        guard response.version == Self.protocolVersion else {
            failAll(with: .unsupportedProtocolVersion(response.version))
            return
        }
        guard let requestID = response.requestID else {
            failAll(with: .missingRequestID)
            return
        }
        guard pending[requestID] != nil else {
            failAll(with: .unexpectedRequestID(requestID))
            return
        }
        if !response.ok {
            guard let error = response.error else {
                failRequest(requestID, with: .malformedResponse("failed response without an error object"))
                return
            }
            failRequest(requestID, with: .hostError(code: error.code, message: error.message))
            return
        }
        resumeRequest(requestID, with: line)
    }

    private func processStderr(_ data: Data) {
        stderrBuffer.append(data)
        while let newline = stderrBuffer.firstIndex(of: 0x0A) {
            var line = Data(stderrBuffer.prefix(upTo: newline))
            stderrBuffer.removeSubrange(...newline)
            if line.last == 0x0D {
                line.removeLast()
            }
            diagnostics.append(String(decoding: line, as: UTF8.self))
            if diagnostics.count > 50 {
                diagnostics.removeFirst(diagnostics.count - 50)
            }
        }
    }

    private func resumeRequest(_ requestID: String, with data: Data) {
        let continuation = pending.removeValue(forKey: requestID)
        continuation?.resume(returning: data)
    }

    private func failRequest(_ requestID: String, with error: HostClientError) {
        let continuation = pending.removeValue(forKey: requestID)
        continuation?.resume(throwing: error)
    }

    private func failAll(with error: HostClientError) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func finish(with error: HostClientError) {
        guard terminalError == nil else { return }
        terminalError = error
        failAll(with: error)
    }
}

/// Production composition of the Host API over exactly one `farrelay-host` exec.
enum FarRelayHostConnection {
    static let command = "farrelay-host"

    static func withClient(
        session: SSHSession,
        operation: @escaping @Sendable (FarRelayHostClient) async throws -> Void
    ) async throws {
        try await session.withExec(command) { transport in
            let client = FarRelayHostClient(transport: transport)
            await client.start()
            do {
                try await operation(client)
                await client.close()
            } catch {
                await client.close()
                throw error
            }
        }
    }
}

private struct HostRequest<Parameters: Encodable>: Encodable {
    let version: Int
    let requestID: String
    let operation: String
    let params: Parameters

    enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case operation
        case params
    }
}

private struct HostResponse<Result: Decodable>: Decodable {
    let version: Int
    let requestID: String?
    let ok: Bool
    let result: Result?
    let error: HostProtocolError?

    enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case ok
        case result
        case error
    }
}

private struct HostResponseHeader: Decodable {
    let version: Int
    let requestID: String?
    let ok: Bool
    let error: HostProtocolError?

    enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case ok
        case error
    }
}

private struct HostProtocolError: Decodable {
    let code: String
    let message: String
}

private struct HostEmptyParameters: Encodable, Sendable {}

private struct HostProcessInfoParameters: Encodable, Sendable {
    let pid: UInt32
}

private struct HostVoiceOverMoveParameters: Encodable, Sendable {
    let direction: VoiceOverMoveDirection
}
