import XCTest
import Citadel
@testable import Nvdr

final class SSHConnectionSupervisorTests: XCTestCase {
    func testNeverDoesNotReconnectAfterTransientFailure() async {
        let connection = FakeConnection(identifier: "first", failingConnectAttempts: 1)
        let factory = FakeConnectionFactory(connections: [connection])
        let supervisor = SSHConnectionSupervisor<FakeConnection>(reconnectPolicy: .never) {
            await factory.makeConnection()
        }

        await supervisor.run { _ in throw SSHSessionError.notConnected }

        let connectionCount = await connection.connectCount()
        let factoryRequests = await factory.requestCount()
        XCTAssertEqual(connectionCount, 1)
        XCTAssertEqual(factoryRequests, 1)
    }

    func testTransientFailureCreatesNewConnectionAndRunsOperationAgain() async {
        let first = FakeConnection(identifier: "first")
        let second = FakeConnection(identifier: "second")
        let factory = FakeConnectionFactory(connections: [first, second])
        let operation = RetryThenWaitOperation(failuresBeforeWaiting: 1)
        let supervisor = SSHConnectionSupervisor<FakeConnection>(
            reconnectPolicy: .automatic(),
            sleeper: ImmediateSleeper()
        ) {
            await factory.makeConnection()
        }

        let run = Task {
            await supervisor.run { connection in
                try await operation.run(on: connection)
            }
        }
        await operation.waitForInvocation(2)
        await supervisor.stop()
        await run.value

        let identifiers = await operation.connectionIdentifiers()
        let factoryRequests = await factory.requestCount()
        XCTAssertEqual(identifiers, ["first", "second"])
        XCTAssertEqual(factoryRequests, 2)
    }

    func testBackoffGrowsAndCaps() {
        let policy = SSHReconnectPolicy.automatic(
            initialDelay: .seconds(1),
            maximumDelay: .seconds(3),
            multiplier: 2,
            maximumAttempts: nil
        )

        XCTAssertEqual(policy.delay(forRetryAttempt: 1), .seconds(1))
        XCTAssertEqual(policy.delay(forRetryAttempt: 2), .seconds(2))
        XCTAssertEqual(policy.delay(forRetryAttempt: 3), .seconds(3))
        XCTAssertEqual(policy.delay(forRetryAttempt: 8), .seconds(3))
    }

    func testSuccessfulConnectionResetsBackoff() async {
        let connection = FakeConnection(identifier: "reused")
        let factory = FakeConnectionFactory(connections: [connection])
        let sleeper = RecordingSleeper()
        let operation = RetryThenWaitOperation(failuresBeforeWaiting: 2)
        let supervisor = SSHConnectionSupervisor<FakeConnection>(
            reconnectPolicy: .automatic(),
            sleeper: sleeper
        ) {
            await factory.makeConnection()
        }

        let run = Task {
            await supervisor.run { connection in
                try await operation.run(on: connection)
            }
        }
        await operation.waitForInvocation(3)
        await supervisor.stop()
        await run.value

        let delays = await sleeper.delays()
        XCTAssertEqual(delays, [.seconds(1), .seconds(1)])
    }

    func testCancellationDuringBackoffStopsImmediately() async {
        let connection = FakeConnection(identifier: "first", failingConnectAttempts: 1)
        let factory = FakeConnectionFactory(connections: [connection])
        let sleeper = BlockingSleeper()
        let supervisor = SSHConnectionSupervisor<FakeConnection>(
            reconnectPolicy: .automatic(),
            sleeper: sleeper
        ) {
            await factory.makeConnection()
        }

        let run = Task { await supervisor.run { _ in } }
        await sleeper.waitUntilSleeping()
        run.cancel()
        await run.value

        let factoryRequests = await factory.requestCount()
        let health = await supervisor.health()
        XCTAssertEqual(factoryRequests, 1)
        XCTAssertEqual(health.lifecycleState, .stopped)
    }

    func testUserStopDuringBackoffNeverReconnects() async {
        let connection = FakeConnection(identifier: "first", failingConnectAttempts: 1)
        let factory = FakeConnectionFactory(connections: [connection])
        let sleeper = BlockingSleeper()
        let supervisor = SSHConnectionSupervisor<FakeConnection>(
            reconnectPolicy: .automatic(),
            sleeper: sleeper
        ) {
            await factory.makeConnection()
        }

        let run = Task { await supervisor.run { _ in } }
        await sleeper.waitUntilSleeping()
        await supervisor.stop()
        await run.value

        let factoryRequests = await factory.requestCount()
        let health = await supervisor.health()
        XCTAssertEqual(factoryRequests, 1)
        XCTAssertEqual(health.desiredState, .stopped)
    }

    func testHostKeyChangeAndAuthenticationFailuresAreNotRetryable() {
        let hostKeyChange = SSHHostIdentityError.hostKeyChanged(
            SSHHostKeyChange(
                host: "example.com",
                port: 22,
                expectedFingerprint: "SHA256:old",
                presentedFingerprint: "SHA256:new"
            )
        )

        XCTAssertEqual(SSHRetryClassifier.decision(for: hostKeyChange), .doNotRetry)
        XCTAssertEqual(SSHRetryClassifier.decision(for: SSHAuthenticationError.missingKey), .doNotRetry)
        XCTAssertEqual(
            SSHRetryClassifier.decision(for: SSHClientError.allAuthenticationOptionsFailed),
            .doNotRetry
        )
    }

    func testInputStateDropsEventsAcrossDisconnectBoundary() {
        var input = SSHInputState()

        XCTAssertEqual(input.command(forKey: 0x11, pressed: true)?.line, "key 17 1")
        input.reset()
        XCTAssertNil(input.command(forKey: 0x11, pressed: false))
        XCTAssertEqual(input.command(forKey: 0x11, pressed: true)?.line, "key 17 1")
    }

    func testAutomaticPolicyCanBoundItsRetryCount() {
        let policy = SSHReconnectPolicy.automatic(maximumAttempts: 2)

        XCTAssertNotNil(policy.delay(forRetryAttempt: 1))
        XCTAssertNotNil(policy.delay(forRetryAttempt: 2))
        XCTAssertNil(policy.delay(forRetryAttempt: 3))
    }
}

private actor FakeConnection: SSHConnection {
    nonisolated let identifier: String
    private var remainingConnectFailures: Int
    private var connections = 0

    init(identifier: String, failingConnectAttempts: Int = 0) {
        self.identifier = identifier
        remainingConnectFailures = failingConnectAttempts
    }

    func connect() async throws {
        connections += 1
        if remainingConnectFailures > 0 {
            remainingConnectFailures -= 1
            throw SSHSessionError.connectedOperationEnded
        }
    }

    func close() async throws {}

    func connectCount() -> Int { connections }
}

private actor FakeConnectionFactory {
    private var connections: [FakeConnection]
    private var requests = 0

    init(connections: [FakeConnection]) {
        self.connections = connections
    }

    func makeConnection() -> FakeConnection {
        requests += 1
        if connections.count > 1 {
            return connections.removeFirst()
        }
        return connections[0]
    }

    func requestCount() -> Int { requests }
}

private struct ImmediateSleeper: SSHRetrySleeper {
    func sleep(for duration: Duration) async throws {}
}

private actor RecordingSleeper: SSHRetrySleeper {
    private var recordedDelays: [Duration] = []

    func sleep(for duration: Duration) async throws {
        recordedDelays.append(duration)
    }

    func delays() -> [Duration] { recordedDelays }
}

private actor BlockingSleeper: SSHRetrySleeper {
    private var sleeping = false
    private var waiter: CheckedContinuation<Void, Never>?

    func sleep(for duration: Duration) async throws {
        sleeping = true
        waiter?.resume()
        waiter = nil
        try await Task.sleep(for: .seconds(60))
    }

    func waitUntilSleeping() async {
        if sleeping { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

private actor RetryThenWaitOperation {
    private let failuresBeforeWaiting: Int
    private var invocations = 0
    private var identifiers: [String] = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(failuresBeforeWaiting: Int) {
        self.failuresBeforeWaiting = failuresBeforeWaiting
    }

    func run(on connection: FakeConnection) async throws {
        invocations += 1
        identifiers.append(connection.identifier)
        resumeWaiters()
        if invocations <= failuresBeforeWaiting {
            throw SSHSessionError.connectedOperationEnded
        }
        try await Task.sleep(for: .seconds(60))
    }

    func waitForInvocation(_ target: Int) async {
        if invocations >= target { return }
        await withCheckedContinuation { continuation in
            waiters[target, default: []].append(continuation)
        }
    }

    func connectionIdentifiers() -> [String] { identifiers }

    private func resumeWaiters() {
        let readyTargets = waiters.keys.filter { $0 <= invocations }
        for target in readyTargets {
            let continuations = waiters.removeValue(forKey: target) ?? []
            continuations.forEach { $0.resume() }
        }
    }
}
