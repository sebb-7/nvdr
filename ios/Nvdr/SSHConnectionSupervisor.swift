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
    private var currentConnection: Connection?
    private var activeSleep: Task<Void, Error>?

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
    /// connection so an operation waiting on a dead stream can unwind.
    func stop() async {
        desiredState = .stopped
        activeSleep?.cancel()
        guard let currentConnection else { return }
        try? await currentConnection.close()
    }

    func run(
        operation: @escaping @Sendable (Connection) async throws -> Void
    ) async {
        guard desiredState != .running else { return }
        desiredState = .running

        defer {
            activeSleep?.cancel()
            activeSleep = nil
            currentConnection = nil
            reportsActive = false
            nextRetryDelay = nil
            desiredState = .stopped
            if case .failed = lifecycleState {
                eventContinuation.finish()
            } else {
                transition(to: .stopped, event: .stopped)
                eventContinuation.finish()
            }
        }

        while desiredState == .running, !Task.isCancelled {
            transition(to: .connecting, event: .connecting)
            let connection = await makeConnection()
            currentConnection = connection

            do {
                try Task.checkCancellation()
                try await connection.connect()
                try Task.checkCancellation()
                guard desiredState == .running else { break }

                reportsActive = true
                reconnectAttempt = 0
                nextRetryDelay = nil
                transition(to: .connected, event: .connected)
                try await operation(connection)

                // A persistent operation should only return after Stop. A
                // remote exec/channel ending otherwise is treated as a lost
                // operation and, when safe, rebuilt on a new SSH connection.
                if desiredState == .running, !Task.isCancelled {
                    throw SSHSessionError.connectedOperationEnded
                }
            } catch is CancellationError {
                try? await connection.close()
                currentConnection = nil
                reportsActive = false
                break
            } catch {
                if desiredState != .running || Task.isCancelled { break }

                let failure = SSHConnectionFailure(error)
                mostRecentDisconnect = failure
                reportsActive = false
                try? await connection.close()
                currentConnection = nil
                eventContinuation.yield(.disconnected(reason: failure))

                guard SSHRetryClassifier.decision(for: error) == .retry else {
                    transition(to: .failed(failure), event: .permanentlyFailed(reason: failure))
                    return
                }

                reconnectAttempt += 1
                guard let delay = reconnectPolicy.delay(forRetryAttempt: reconnectAttempt) else {
                    transition(to: .failed(failure), event: .permanentlyFailed(reason: failure))
                    return
                }

                nextRetryDelay = delay
                transition(
                    to: .reconnecting(attempt: reconnectAttempt, delay: delay, reason: failure),
                    event: .reconnecting(attempt: reconnectAttempt, delay: delay, reason: failure)
                )

                do {
                    try await waitForRetry(delay)
                } catch is CancellationError {
                    break
                } catch {
                    break
                }
            }
        }
    }

    private func waitForRetry(_ delay: Duration) async throws {
        let sleep = Task { [sleeper] in
            try await sleeper.sleep(for: delay)
        }
        activeSleep = sleep
        defer { activeSleep = nil }
        try await withTaskCancellationHandler {
            try await sleep.value
        } onCancel: {
            sleep.cancel()
        }
    }

    private func transition(
        to state: SSHConnectionLifecycleState,
        event: SSHConnectionLifecycleEvent
    ) {
        lifecycleState = state
        eventContinuation.yield(event)
    }
}
