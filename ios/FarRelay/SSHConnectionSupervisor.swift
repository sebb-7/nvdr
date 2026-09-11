import Foundation
import Citadel
import NIOCore

/// The user's intent for a long-lived connected operation. This remains
/// separate from the state of the underlying SSH socket.
enum SSHSessionDesiredState: Sendable, Equatable {
    case running
    case stopped
}

/// A non-library-specific description of an SSH connection failure.
struct SSHConnectionFailure: Sendable, Equatable {
    let message: String

    init(_ error: Error) {
        message = error.localizedDescription
    }
}

enum SSHConnectionLifecycleState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int, delay: Duration, reason: SSHConnectionFailure)
    case stopped
    case failed(SSHConnectionFailure)
}

enum SSHConnectionLifecycleEvent: Sendable, Equatable {
    case connecting
    case connected
    case disconnected(reason: SSHConnectionFailure)
    case reconnecting(attempt: Int, delay: Duration, reason: SSHConnectionFailure)
    case permanentlyFailed(reason: SSHConnectionFailure)
    case stopped
}

struct SSHConnectionHealth: Sendable, Equatable {
    let desiredState: SSHSessionDesiredState
    let lifecycleState: SSHConnectionLifecycleState
    let reconnectAttempt: Int
    let nextRetryDelay: Duration?
    let mostRecentDisconnect: SSHConnectionFailure?
    let reportsActive: Bool
}

/// The retry policy is intentionally independent from Citadel's built-in
/// reconnect mode: a dropped SSH connection also invalidates its exec
/// channels, so the whole connected operation must be recreated.
enum SSHReconnectPolicy: Sendable, Equatable {
    case never
    case automatic(
        initialDelay: Duration = .seconds(1),
        maximumDelay: Duration = .seconds(30),
        multiplier: Double = 2,
        maximumAttempts: Int? = nil
    )

    /// Returns nil when no more reconnect attempts should be made.
    func delay(forRetryAttempt attempt: Int) -> Duration? {
        guard attempt > 0 else { return nil }
        guard case let .automatic(initialDelay, maximumDelay, multiplier, maximumAttempts) = self else {
            return nil
        }
        if let maximumAttempts, attempt > maximumAttempts {
            return nil
        }

        let initialNanoseconds = Self.nanoseconds(in: initialDelay)
        let maximumNanoseconds = Self.nanoseconds(in: maximumDelay)
        guard initialNanoseconds > 0, maximumNanoseconds >= initialNanoseconds, multiplier >= 1 else {
            return nil
        }
        let scaled = initialNanoseconds * pow(multiplier, Double(attempt - 1))
        let capped = min(scaled, maximumNanoseconds)
        return .nanoseconds(Int64(capped.rounded(.down)))
    }

    private static func nanoseconds(in duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000_000_000
            + Double(components.attoseconds) / 1_000_000_000
    }
}

enum SSHRetryDecision: Sendable, Equatable {
    case retry
    case doNotRetry
}

/// Typed retry classification at the SSH boundary. Unknown library failures
/// fail closed instead of being retried based on localized error text.
enum SSHRetryClassifier {
    static func decision(for error: Error) -> SSHRetryDecision {
        if error is CancellationError || error is SSHAuthenticationError || error is SSHHostIdentityError {
            return .doNotRetry
        }

        if let error = error as? SSHSessionError {
            switch error {
            case .connectedOperationEnded:
                return .retry
            case .notConnected:
                return .doNotRetry
            }
        }

        if let error = error as? SSHClientError {
            switch error {
            case .allAuthenticationOptionsFailed,
                    .unsupportedPasswordAuthentication,
                    .unsupportedPrivateKeyAuthentication,
                    .unsupportedHostBasedAuthentication:
                return .doNotRetry
            case .channelCreationFailed:
                return .retry
            }
        }

        if let error = error as? CitadelError {
            switch error {
            case .channelFailure, .channelCreationFailed:
                return .retry
            default:
                return .doNotRetry
            }
        }

        if error is ChannelError || error is IOError {
            return .retry
        }

        // Citadel's command failures and all other unknown failures may be
        // configuration or protocol problems. Do not loop on them.
        return .doNotRetry
    }
}

protocol SSHRetrySleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

struct TaskSSHRetrySleeper: SSHRetrySleeper {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// The small contract the supervisor needs from a reconnectable SSH client.
/// `SSHSession` conforms, while tests provide in-memory connections.
protocol SSHConnection: Sendable {
    func connect() async throws
    func close() async throws
}

/// Describes why a connected operation returned. The supervisor owns SSH
/// lifecycle only; application protocols choose whether their normal
/// completion is intentional or indicates that a persistent operation died.
enum SSHConnectedOperationCompletion: Sendable, Equatable {
    case completedIntentionally
    case unexpectedlyEnded
}

/// Runs a generic operation against a connected SSH session and recreates the
/// entire connection and operation after a classified transient failure.
///
/// The operation receives no app-specific command or protocol information,
/// allowing a future PTY or another SSH-backed protocol to use the same
/// lifecycle machinery.
actor SSHConnectionSupervisor<Connection: SSHConnection> {
    nonisolated let lifecycleEvents: AsyncStream<SSHConnectionLifecycleEvent>

    private let eventContinuation: AsyncStream<SSHConnectionLifecycleEvent>.Continuation
    private let makeConnection: @Sendable () async -> Connection
    private let reconnectPolicy: SSHReconnectPolicy
    private let sleeper: any SSHRetrySleeper
    private var desiredState: SSHSessionDesiredState = .stopped
    private var lifecycleState: SSHConnectionLifecycleState = .idle
    private var reconnectAttempt = 0
    private var nextRetryDelay: Duration?
    private var mostRecentDisconnect: SSHConnectionFailure?
    private var reportsActive = false
    private var currentConnection: (generation: Int, connection: Connection)?
    private var activeSleep: (generation: Int, task: Task<Void, Error>)?
    private var generation = 0
    private var activeGeneration: Int?

    init(
        reconnectPolicy: SSHReconnectPolicy,
        sleeper: any SSHRetrySleeper = TaskSSHRetrySleeper(),
        makeConnection: @escaping @Sendable () async -> Connection
    ) {
        let stream = AsyncStream<SSHConnectionLifecycleEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        lifecycleEvents = stream.stream
        eventContinuation = stream.continuation
        self.reconnectPolicy = reconnectPolicy
        self.sleeper = sleeper
        self.makeConnection = makeConnection
    }

    func health() -> SSHConnectionHealth {
        SSHConnectionHealth(
            desiredState: desiredState,
            lifecycleState: lifecycleState,
            reconnectAttempt: reconnectAttempt,
            nextRetryDelay: nextRetryDelay,
            mostRecentDisconnect: mostRecentDisconnect,
            reportsActive: reportsActive
        )
    }

    /// Stop is idempotent. It cancels retry sleep and closes the active
    /// connection so an operation waiting on a dead stream can unwind. The
    /// generation changes before awaiting close, so a late connect result can
    /// never become active after a new run has begun.
    func stop() async {
        desiredState = .stopped
        generation += 1
        activeGeneration = nil
        activeSleep?.task.cancel()
        activeSleep = nil
        let connection = currentConnection?.connection
        currentConnection = nil
        reportsActive = false
        nextRetryDelay = nil
        transition(to: .stopped, event: .stopped)
        try? await connection?.close()
    }

    func run(
        operation: @escaping @Sendable (Connection) async throws -> SSHConnectedOperationCompletion
    ) async {
        guard desiredState != .running else { return }
        generation += 1
        let runGeneration = generation
        activeGeneration = runGeneration
        desiredState = .running

        defer {
            if owns(runGeneration) {
                if activeSleep?.generation == runGeneration {
                    activeSleep?.task.cancel()
                    activeSleep = nil
                }
                if currentConnection?.generation == runGeneration {
                    currentConnection = nil
                }
                reportsActive = false
                nextRetryDelay = nil
                activeGeneration = nil
                desiredState = .stopped
                if case .failed = lifecycleState {
                    // Preserve a terminal non-retryable failure for observers.
                } else {
                    transition(to: .stopped, event: .stopped)
                }
            }
        }

        while canProceed(runGeneration), !Task.isCancelled {
            transition(to: .connecting, event: .connecting, for: runGeneration)
            let connection = await makeConnection()
            guard canProceed(runGeneration), !Task.isCancelled else {
                try? await connection.close()
                break
            }
            currentConnection = (runGeneration, connection)

            do {
                try Task.checkCancellation()
                try await connection.connect()
                try Task.checkCancellation()
                guard canProceed(runGeneration) else {
                    try? await connection.close()
                    clearCurrentConnection(for: runGeneration)
                    break
                }

                reportsActive = true
                reconnectAttempt = 0
                nextRetryDelay = nil
                transition(to: .connected, event: .connected, for: runGeneration)
                let completion = try await operation(connection)

                guard canProceed(runGeneration), !Task.isCancelled else {
                    try? await connection.close()
                    clearCurrentConnection(for: runGeneration)
                    break
                }
                switch completion {
                case .completedIntentionally:
                    desiredState = .stopped
                    try? await connection.close()
                    clearCurrentConnection(for: runGeneration)
                case .unexpectedlyEnded:
                    throw SSHSessionError.connectedOperationEnded
                }
            } catch is CancellationError {
                try? await connection.close()
                clearCurrentConnection(for: runGeneration)
                reportsActive = false
                break
            } catch {
                guard canProceed(runGeneration), !Task.isCancelled else {
                    try? await connection.close()
                    clearCurrentConnection(for: runGeneration)
                    break
                }

                let failure = SSHConnectionFailure(error)
                mostRecentDisconnect = failure
                reportsActive = false
                try? await connection.close()
                clearCurrentConnection(for: runGeneration)
                guard canProceed(runGeneration), !Task.isCancelled else { break }
                emit(.disconnected(reason: failure), for: runGeneration)

                guard SSHRetryClassifier.decision(for: error) == .retry else {
                    transition(
                        to: .failed(failure),
                        event: .permanentlyFailed(reason: failure),
                        for: runGeneration
                    )
                    return
                }

                reconnectAttempt += 1
                guard let delay = reconnectPolicy.delay(forRetryAttempt: reconnectAttempt) else {
                    transition(
                        to: .failed(failure),
                        event: .permanentlyFailed(reason: failure),
                        for: runGeneration
                    )
                    return
                }

                nextRetryDelay = delay
                transition(
                    to: .reconnecting(attempt: reconnectAttempt, delay: delay, reason: failure),
                    event: .reconnecting(attempt: reconnectAttempt, delay: delay, reason: failure),
                    for: runGeneration
                )

                do {
                    try await waitForRetry(delay, generation: runGeneration)
                } catch is CancellationError {
                    break
                } catch {
                    break
                }
            }
        }
    }

    private func waitForRetry(_ delay: Duration, generation: Int) async throws {
        let sleep = Task { [sleeper] in
            try await sleeper.sleep(for: delay)
        }
        activeSleep = (generation, sleep)
        defer {
            if activeSleep?.generation == generation {
                activeSleep = nil
            }
        }
        try await withTaskCancellationHandler {
            try await sleep.value
        } onCancel: {
            sleep.cancel()
        }
    }

    private func owns(_ generation: Int) -> Bool {
        activeGeneration == generation
    }

    private func canProceed(_ generation: Int) -> Bool {
        owns(generation) && desiredState == .running
    }

    private func clearCurrentConnection(for generation: Int) {
        guard currentConnection?.generation == generation else { return }
        currentConnection = nil
    }

    private func transition(
        to state: SSHConnectionLifecycleState,
        event: SSHConnectionLifecycleEvent,
        for generation: Int? = nil
    ) {
        if let generation, !owns(generation) { return }
        lifecycleState = state
        eventContinuation.yield(event)
    }

    private func emit(_ event: SSHConnectionLifecycleEvent, for generation: Int) {
        guard owns(generation) else { return }
        eventContinuation.yield(event)
    }
}
