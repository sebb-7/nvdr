import Foundation

/// Presentation-neutral lifecycle state for one interactive SSH terminal.
enum SSHTerminalSessionState: Equatable, Sendable {
    case idle
    case running
    case ended
    case closed
    case failed(String)

    fileprivate var isActive: Bool {
        self == .running
    }
}

enum SSHTerminalSessionError: LocalizedError, Equatable, Sendable {
    case notRunning

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "The SSH terminal session is not running."
        }
    }
}

/// Composes one raw SSH PTY transport with the app-owned terminal state.
///
/// The session owns its read task. `close()` cancels that task and unblocks
/// `waitForCompletion()`, allowing the surrounding `SSHSession.withPTY`
/// operation to return and release the underlying channel.
@MainActor
final class SSHTerminalSession {
    private let transport: any SSHPTYTransporting
    private let terminal: TerminalEngine
    private var readTask: Task<Void, Never>?
    private var completionWaiters: [CheckedContinuation<SSHTerminalSessionState, Never>] = []

    private(set) var state: SSHTerminalSessionState = .idle

    init(
        transport: any SSHPTYTransporting,
        columns: Int = 80,
        rows: Int = 24,
        scrollback: Int = 500
    ) {
        self.transport = transport
        terminal = TerminalEngine(columns: columns, rows: rows, scrollback: scrollback)
    }

    deinit {
        readTask?.cancel()
    }

    /// Starts reading the PTY once. A session cannot be restarted after it
    /// reaches a terminal lifecycle state.
    func start() {
        guard state == .idle else { return }
        transition(to: .running)

        let transport = transport
        readTask = Task { [weak self, transport] in
            do {
                try await transport.consumeEvents { [weak self] event in
                    try Task.checkCancellation()
                    guard let self else { throw CancellationError() }
                    try await self.receive(event)
                }
                await self?.finishAtRemoteEOF()
            } catch is CancellationError {
                // `close()` owns the resulting state and has already resumed
                // waiters. A cancelled reader must not overwrite it.
            } catch {
                await self?.recordTransportFailure(error)
            }
        }
    }

    /// Cancels the bridge task. This is idempotent and deliberately does not
    /// mutate a completed or failed terminal state.
    func close() {
        guard state.isActive || state == .idle else { return }
        readTask?.cancel()
        readTask = nil
        transition(to: .closed)
    }

    /// Waits for EOF, close, or a transport error after `start()`.
    func waitForCompletion() async -> SSHTerminalSessionState {
        guard state.isActive else { return state }
        return await withCheckedContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }

    /// Returns an immutable terminal value suitable for presentation code.
    func snapshot() -> TerminalSnapshot {
        terminal.snapshot()
    }

    /// Sends unmodified bytes so control sequences, UTF-8, and paste data keep
    /// their original representation.
    func send(_ bytes: Data) async throws {
        try requireRunning()
        do {
            try await transport.write(bytes)
        } catch {
            recordTransportFailure(error)
            throw error
        }
    }

    /// Updates the local parser before resizing the remote PTY. This makes an
    /// immediately requested snapshot match the dimensions the user selected,
    /// even while the remote resize is in flight.
    func resize(
        columns: Int,
        rows: Int,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0
    ) async throws {
        try requireRunning()
        _ = try SSHPTYDimensions(
            columns: columns,
            rows: rows,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        terminal.resize(columns: columns, rows: rows)
        do {
            try await transport.resize(
                columns: columns,
                rows: rows,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        } catch {
            recordTransportFailure(error)
            throw error
        }
    }

    private func receive(_ event: SSHPTYEvent) throws {
        guard state == .running else { throw CancellationError() }
        switch event {
        case .stdout(let bytes), .stderr(let bytes):
            terminal.feed(bytes)
        }
    }

    private func finishAtRemoteEOF() {
        guard state == .running else { return }
        readTask = nil
        transition(to: .ended)
    }

    private func recordTransportFailure(_ error: Error) {
        guard state == .running else { return }
        readTask?.cancel()
        readTask = nil
        transition(to: .failed(error.localizedDescription))
    }

    private func requireRunning() throws {
        guard state == .running else { throw SSHTerminalSessionError.notRunning }
    }

    private func transition(to newState: SSHTerminalSessionState) {
        state = newState
        guard !newState.isActive else { return }
        let waiters = completionWaiters
        completionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: newState)
        }
    }
}
