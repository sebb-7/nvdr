import Foundation
import Observation

/// Feature lifecycle state for the one interactive terminal owned by the app.
enum SSHTerminalHostState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case ended
    case failed(String)
    case closed

    var presentationState: TerminalPresentationSessionState {
        switch self {
        case .idle: .idle
        case .connecting: .connecting
        case .connected: .connected
        case .ended: .ended
        case .failed(let message): .failed(message)
        case .closed: .closed
        }
    }
}

/// The narrow connection surface needed by the terminal feature host.
protocol SSHTerminalHostConnection: Sendable {
    func connect() async throws
    func withTerminalPTY(
        configuration: SSHPTYConfiguration,
        operation: @escaping @Sendable (any SSHPTYTransporting) async throws -> Void
    ) async throws
    func close() async throws
}

protocol SSHTerminalHostConnectionFactory: Sendable {
    func makeConnection(
        configuration: SSHSessionConfiguration
    ) -> any SSHTerminalHostConnection
}

struct ProductionSSHTerminalHostConnectionFactory: SSHTerminalHostConnectionFactory {
    func makeConnection(
        configuration: SSHSessionConfiguration
    ) -> any SSHTerminalHostConnection {
        SSHSession(configuration: configuration)
    }
}

extension SSHSession: SSHTerminalHostConnection {
    func withTerminalPTY(
        configuration: SSHPTYConfiguration,
        operation: @escaping @Sendable (any SSHPTYTransporting) async throws -> Void
    ) async throws {
        try await withPTY(configuration: configuration) { transport in
            try await operation(transport)
        }
    }
}

/// Owns composition and top-level lifecycle for one interactive SSH terminal.
/// Parsing, accessibility interpretation, and presentation remain in their
/// dedicated lower layers.
@Observable
@MainActor
final class SSHTerminalHost {
    private(set) var state: SSHTerminalHostState = .idle
    let presentation = TerminalPresentationModel()

    private let connectionFactory: any SSHTerminalHostConnectionFactory
    private var connection: (any SSHTerminalHostConnection)?
    private var terminalSession: SSHTerminalSession?
    private var driver: Task<Void, Never>?
    private var generation = 0

    init(
        connectionFactory: any SSHTerminalHostConnectionFactory = ProductionSSHTerminalHostConnectionFactory()
    ) {
        self.connectionFactory = connectionFactory
    }

    isolated deinit {
        terminalSession?.close()
        driver?.cancel()
        let connection = connection
        Task {
            try? await connection?.close()
        }
    }

    /// Starts the terminal using the same saved endpoint, credentials, and
    /// host-key policy as the existing NVDA bridge connection.
    func start(settings: AppSettings) async {
        let host = settings.sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = settings.sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !user.isEmpty else {
            fail("Set SSH host and user in Settings before opening the terminal.")
            return
        }
        await start(configuration: settings.sshSessionConfiguration())
    }

    /// A configuration entry point keeps lifecycle tests deterministic without
    /// creating a second app settings or credential system.
    func start(configuration: SSHSessionConfiguration) async {
        await close()
        do {
            _ = try SSHSession.authenticationSummary(for: configuration)
        } catch {
            fail(error.localizedDescription)
            return
        }

        generation &+= 1
        let generation = generation
        let connection = connectionFactory.makeConnection(configuration: configuration)
        self.connection = connection
        transition(to: .connecting)
        presentation.beginConnecting()
        driver = Task { [weak self] in
            await self?.run(
                connection: connection,
                generation: generation
            )
        }
    }

    /// Closes the PTY reader before releasing the SSH connection. Repeated
    /// close calls are safe and do not start replacement work.
    func close() async {
        generation &+= 1
        let terminalSession = terminalSession
        self.terminalSession = nil
        terminalSession?.close()

        driver?.cancel()
        driver = nil
        let connection = connection
        self.connection = nil
        transition(to: .closed)
        try? await connection?.close()
    }

    private func run(
        connection: any SSHTerminalHostConnection,
        generation: Int
    ) async {
        do {
            try await connection.connect()
            try ensureCurrent(generation)
            let ptyConfiguration = try SSHPTYConfiguration()
            try await connection.withTerminalPTY(configuration: ptyConfiguration) { [weak self] transport in
                guard let self else { throw CancellationError() }
                try await self.runTerminal(transport: transport, generation: generation)
            }
            await release(connection: connection, generation: generation)
        } catch is CancellationError {
            await release(connection: connection, generation: generation)
        } catch {
            guard isCurrent(generation) else { return }
            fail(startupFailureMessage(for: error))
            await release(connection: connection, generation: generation)
        }
    }

    private func runTerminal(
        transport: any SSHPTYTransporting,
        generation: Int
    ) async throws {
        try ensureCurrent(generation)
        let session = SSHTerminalSession(transport: transport)
        terminalSession = session
        session.start()
        presentation.attach(session)
        transition(to: .connected)

        let terminalState = await session.waitForCompletion()
        try ensureCurrent(generation)
        terminalSession = nil
        presentation.refresh()
        switch terminalState {
        case .ended:
            transition(to: .ended)
        case .failed(let message):
            fail("Terminal session failed: \(message)")
        case .closed:
            transition(to: .closed)
        case .idle, .running:
            fail("Terminal session ended unexpectedly.")
        }
    }

    private func release(
        connection: any SSHTerminalHostConnection,
        generation: Int
    ) async {
        guard isCurrent(generation) else { return }
        try? await connection.close()
        guard isCurrent(generation) else { return }
        self.connection = nil
        driver = nil
        if state == .connected {
            transition(to: .ended)
        }
    }

    private func ensureCurrent(_ generation: Int) throws {
        guard isCurrent(generation), !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation
    }

    private func startupFailureMessage(for error: Error) -> String {
        if error is SSHAuthenticationError {
            return error.localizedDescription
        }
        return "Unable to start the SSH terminal. Check the host, network, and credentials."
    }

    private func fail(_ message: String) {
        transition(to: .failed(message))
    }

    private func transition(to newState: SSHTerminalHostState) {
        state = newState
        presentation.setSessionState(newState.presentationState)
    }
}
