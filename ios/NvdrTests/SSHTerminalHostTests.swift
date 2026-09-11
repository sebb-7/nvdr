import Foundation
import XCTest
@testable import Nvdr

@MainActor
final class SSHTerminalHostTests: XCTestCase {
    func testStartBuildsTerminalStackAndExposesPresentationSession() async {
        let connection = FakeTerminalHostConnection()
        let host = SSHTerminalHost(connectionFactory: FakeTerminalHostConnectionFactory(connection: connection))

        await host.start(configuration: configuration())
        await waitUntil { host.state == .connected }

        XCTAssertEqual(host.presentation.sessionState, .connected)
        XCTAssertNotNil(host.presentation.accessibleSnapshot)
        let didConnect = await connection.didConnect()
        let didOpenPTY = await connection.didOpenPTY()
        XCTAssertTrue(didConnect)
        XCTAssertTrue(didOpenPTY)

        await waitUntil { await connection.isReaderReady() }
        await host.close()
        await waitUntil { await connection.didClose() }
        XCTAssertEqual(host.state, .closed)
        XCTAssertEqual(host.presentation.sessionState, .closed)
    }

    func testConnectionFailureBecomesAccessibleFeatureFailure() async {
        let connection = FakeTerminalHostConnection(failure: .connect)
        let host = SSHTerminalHost(connectionFactory: FakeTerminalHostConnectionFactory(connection: connection))

        await host.start(configuration: configuration())
        await waitUntil {
            if case .failed = host.state { return true }
            return false
        }

        XCTAssertEqual(host.state, .failed("Unable to start the SSH terminal. Check the host, network, and credentials."))
        XCTAssertEqual(
            host.presentation.sessionState,
            .failed("Unable to start the SSH terminal. Check the host, network, and credentials.")
        )
    }

    func testPTYStartupFailureBecomesFeatureFailure() async {
        let connection = FakeTerminalHostConnection(failure: .pty)
        let host = SSHTerminalHost(connectionFactory: FakeTerminalHostConnectionFactory(connection: connection))

        await host.start(configuration: configuration())
        await waitUntil {
            if case .failed = host.state { return true }
            return false
        }

        XCTAssertEqual(host.state, .failed("Unable to start the SSH terminal. Check the host, network, and credentials."))
        let didConnect = await connection.didConnect()
        let didOpenPTY = await connection.didOpenPTY()
        XCTAssertTrue(didConnect)
        XCTAssertTrue(didOpenPTY)
    }

    func testCloseIsIdempotentAndReleasesOwnedTerminalWork() async {
        let connection = FakeTerminalHostConnection()
        let host = SSHTerminalHost(connectionFactory: FakeTerminalHostConnectionFactory(connection: connection))

        await host.start(configuration: configuration())
        await waitUntil { host.state == .connected }
        await waitUntil { await connection.isReaderReady() }
        await host.close()
        await host.close()
        await waitUntil { await connection.didObserveReaderCancellation() }

        let closeCount = await connection.closeCount()
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(host.state, .closed)
    }

    func testFeatureTeardownReleasesTerminalWorkBeforeHostDeallocation() async {
        let connection = FakeTerminalHostConnection()
        var host: SSHTerminalHost? = SSHTerminalHost(
            connectionFactory: FakeTerminalHostConnectionFactory(connection: connection)
        )

        await host?.start(configuration: configuration())
        await waitUntil { host?.state == .connected }
        await waitUntil { await connection.isReaderReady() }
        await host?.close()
        weak var releasedHost = host
        host = nil

        await waitUntil { await connection.didObserveReaderCancellation() }
        XCTAssertNil(releasedHost)
    }

    func testTerminalStartupDoesNotModifyNVDAFeatureState() async {
        let connection = FakeTerminalHostConnection()
        let host = SSHTerminalHost(connectionFactory: FakeTerminalHostConnectionFactory(connection: connection))
        let bridge = BridgeClient(speech: SpeechOutput())

        await host.start(configuration: configuration())
        await waitUntil { host.state == .connected }

        XCTAssertEqual(bridge.status, .idle)
        XCTAssertTrue(bridge.log.isEmpty)

        await host.close()
    }

    private func configuration() -> SSHSessionConfiguration {
        SSHSessionConfiguration(
            host: "example.invalid",
            port: 22,
            username: "tester",
            authentication: .password("password")
        )
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

private struct FakeTerminalHostConnectionFactory: SSHTerminalHostConnectionFactory {
    let connection: FakeTerminalHostConnection

    func makeConnection(
        configuration: SSHSessionConfiguration
    ) -> any SSHTerminalHostConnection {
        connection
    }
}

private actor FakeTerminalHostConnection: SSHTerminalHostConnection {
    enum Failure: Equatable, Sendable {
        case connect
        case pty
    }

    private let failure: Failure?
    private let transport = FakeTerminalHostTransport()
    private var connected = false
    private var openedPTY = false
    private var closed = false
    private var closes = 0

    init(failure: Failure? = nil) {
        self.failure = failure
    }

    func connect() async throws {
        if failure == .connect { throw FakeTerminalHostError.connection }
        connected = true
    }

    func withTerminalPTY(
        configuration: SSHPTYConfiguration,
        operation: @escaping @Sendable (any SSHPTYTransporting) async throws -> Void
    ) async throws {
        openedPTY = true
        if failure == .pty { throw FakeTerminalHostError.pty }
        try await operation(transport)
    }

    func close() async throws {
        closes += 1
        closed = true
        await transport.releaseReadLoop()
    }

    func didConnect() -> Bool { connected }
    func didOpenPTY() -> Bool { openedPTY }
    func didClose() -> Bool { closed }
    func closeCount() -> Int { closes }
    func isReaderReady() async -> Bool { await transport.isReaderReady() }
    func didObserveReaderCancellation() async -> Bool {
        await transport.observedCancellation()
    }
}

private actor FakeTerminalHostTransport: SSHPTYTransporting {
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancellationObserved = false
    private var readerReady = false

    func consumeEvents(
        _ handler: @escaping @Sendable (SSHPTYEvent) async throws -> Void
    ) async throws {
        do {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                readerReady = true
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            cancellationObserved = true
            throw CancellationError()
        }
    }

    func write(_ data: Data) async throws {}

    func resize(
        columns: Int,
        rows: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) async throws {}

    func releaseReadLoop() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }

    func observedCancellation() -> Bool { cancellationObserved }
    func isReaderReady() -> Bool { readerReady }
}

private enum FakeTerminalHostError: LocalizedError, Sendable {
    case connection
    case pty

    var errorDescription: String? {
        switch self {
        case .connection: "Fake connection failure."
        case .pty: "Fake PTY startup failure."
        }
    }
}
