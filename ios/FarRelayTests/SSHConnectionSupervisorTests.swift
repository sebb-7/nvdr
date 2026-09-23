import XCTest
import Citadel
@testable import FarRelay

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
                return .unexpectedlyEnded
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
                return .unexpectedlyEnded
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

        let run = Task { await supervisor.run { _ in .unexpectedlyEnded } }
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

        let run = Task { await supervisor.run { _ in .unexpectedlyEnded } }
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

    func testInputStatePreservesRepeatedKeyDownEvents() {
        var input = SSHInputState()

        let commands = [
            input.command(forKey: 0x25, pressed: true),
            input.command(forKey: 0x25, pressed: true),
            input.command(forKey: 0x25, pressed: true),
            input.command(forKey: 0x25, pressed: false),
        ]

        XCTAssertEqual(commands.compactMap { $0?.line }, ["key 37 1", "key 37 1", "key 37 1", "key 37 0"])
    }

    func testInputStateEmitsOneNormalDownAndUp() {
        var input = SSHInputState()

        XCTAssertEqual(input.command(forKey: 0x08, pressed: true)?.line, "key 8 1")
        XCTAssertEqual(input.command(forKey: 0x08, pressed: false)?.line, "key 8 0")
    }

    func testInputStateSerializesOptionalCorrelationIDWithoutChangingKeySemantics() {
        var input = SSHInputState()

        XCTAssertEqual(
            input.command(forKey: VK.f5, pressed: true, eventID: 418)?.line,
            "key 116 1 event=418"
        )
        XCTAssertEqual(
            input.command(forKey: VK.f5, pressed: false, eventID: 419)?.line,
            "key 116 0 event=419"
        )
    }

    func testInputStateDropsStaleAndDuplicateKeyUpEvents() {
        var input = SSHInputState()

        XCTAssertEqual(input.command(forKey: 0x41, pressed: true)?.line, "key 65 1")
        input.reset()
        XCTAssertNil(input.command(forKey: 0x41, pressed: false))
        XCTAssertEqual(input.command(forKey: 0x41, pressed: true)?.line, "key 65 1")
        XCTAssertEqual(input.command(forKey: 0x41, pressed: false)?.line, "key 65 0")
        XCTAssertNil(input.command(forKey: 0x41, pressed: false))
    }

    func testStopDuringConnectNeverInvokesConnectedOperationAndClosesLateConnection() async {
        let connection = ControllableConnection(identifier: "pending", waitsForRelease: true)
        let factory = ControllableConnectionFactory(connections: [connection])
        let invocations = ConnectionInvocationRecorder()
        let supervisor = SSHConnectionSupervisor<ControllableConnection>(reconnectPolicy: .automatic()) {
            await factory.makeConnection()
        }

        let run = Task {
            await supervisor.run { connection in
                await invocations.record(connection.identifier)
                return .unexpectedlyEnded
            }
        }
        await connection.waitUntilConnectStarted()
        await supervisor.stop()
        await connection.completeConnect()
        await connection.waitForCloseCount(2)
        await run.value

        let recordedIdentifiers = await invocations.identifiers()
        let closeCount = await connection.closeCount()
        let health = await supervisor.health()
        XCTAssertEqual(recordedIdentifiers, [])
        XCTAssertEqual(closeCount, 2)
        XCTAssertEqual(health.desiredState, .stopped)
    }

    func testLateAttemptCannotOverwriteANewerRun() async {
        let stale = ControllableConnection(identifier: "stale", waitsForRelease: true)
        let current = ControllableConnection(identifier: "current")
        let factory = ControllableConnectionFactory(connections: [stale, current])
        let invocations = ConnectionInvocationRecorder()
        let supervisor = SSHConnectionSupervisor<ControllableConnection>(reconnectPolicy: .automatic()) {
            await factory.makeConnection()
        }

        let staleRun = Task {
            await supervisor.run { connection in
                await invocations.record(connection.identifier)
                return .unexpectedlyEnded
            }
        }
        await stale.waitUntilConnectStarted()
        await supervisor.stop()

        let currentRun = Task {
            await supervisor.run { connection in
                await invocations.record(connection.identifier)
                try await Task.sleep(for: .seconds(60))
                return .unexpectedlyEnded
            }
        }
        await invocations.waitForInvocationCount(1)
        await stale.completeConnect()
        await stale.waitForCloseCount(2)

        let recordedIdentifiers = await invocations.identifiers()
        XCTAssertEqual(recordedIdentifiers, ["current"])
        let health = await supervisor.health()
        XCTAssertEqual(health.lifecycleState, .connected)
        XCTAssertTrue(health.reportsActive)

        await supervisor.stop()
        await staleRun.value
        await currentRun.value
    }

    func testIntentionalCompletionStopsWithoutReconnect() async {
        let connection = FakeConnection(identifier: "first")
        let factory = FakeConnectionFactory(connections: [connection])
        let supervisor = SSHConnectionSupervisor<FakeConnection>(reconnectPolicy: .automatic()) {
            await factory.makeConnection()
        }

        await supervisor.run { _ in .completedIntentionally }

        let factoryRequests = await factory.requestCount()
        let health = await supervisor.health()
        XCTAssertEqual(factoryRequests, 1)
        XCTAssertEqual(health.desiredState, .stopped)
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

private actor ControllableConnection: SSHConnection {
    nonisolated let identifier: String
    private let waitsForRelease: Bool
    private var connectStarted = false
    private var connectStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var connectContinuation: CheckedContinuation<Void, Never>?
    private var connectCompletedEarly = false
    private var closes = 0
    private var closeWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(identifier: String, waitsForRelease: Bool = false) {
        self.identifier = identifier
        self.waitsForRelease = waitsForRelease
    }

    func connect() async throws {
        connectStarted = true
        connectStartWaiters.forEach { $0.resume() }
        connectStartWaiters = []
        guard waitsForRelease else { return }
        if connectCompletedEarly { return }
        await withCheckedContinuation { continuation in
            connectContinuation = continuation
        }
    }

    func close() async throws {
        closes += 1
        resumeCloseWaiters()
    }

    func completeConnect() {
        if let connectContinuation {
            self.connectContinuation = nil
            connectContinuation.resume()
        } else {
            connectCompletedEarly = true
        }
    }

    func waitUntilConnectStarted() async {
        if connectStarted { return }
        await withCheckedContinuation { continuation in
            connectStartWaiters.append(continuation)
        }
    }

    func waitForCloseCount(_ target: Int) async {
        if closes >= target { return }
        await withCheckedContinuation { continuation in
            closeWaiters[target, default: []].append(continuation)
        }
    }

    func closeCount() -> Int { closes }

    private func resumeCloseWaiters() {
        let ready = closeWaiters.keys.filter { $0 <= closes }
        for target in ready {
            let waiters = closeWaiters.removeValue(forKey: target) ?? []
            waiters.forEach { $0.resume() }
        }
    }
}

private actor ControllableConnectionFactory {
    private var connections: [ControllableConnection]

    init(connections: [ControllableConnection]) {
        self.connections = connections
    }

    func makeConnection() -> ControllableConnection {
        if connections.count > 1 {
            return connections.removeFirst()
        }
        return connections[0]
    }
}

private actor ConnectionInvocationRecorder {
    private var recorded: [String] = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ identifier: String) {
        recorded.append(identifier)
        let ready = waiters.keys.filter { $0 <= recorded.count }
        for target in ready {
            let continuations = waiters.removeValue(forKey: target) ?? []
            continuations.forEach { $0.resume() }
        }
    }

    func identifiers() -> [String] { recorded }

    func waitForInvocationCount(_ target: Int) async {
        if recorded.count >= target { return }
        await withCheckedContinuation { continuation in
            waiters[target, default: []].append(continuation)
        }
    }
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
