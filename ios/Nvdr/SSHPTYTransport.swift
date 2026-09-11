import Foundation
@preconcurrency import Citadel
import NIOCore

enum SSHPTYConfigurationError: LocalizedError, Equatable, Sendable {
    case emptyTerminalType
    case nonPositiveColumns
    case nonPositiveRows
    case negativePixelWidth
    case negativePixelHeight
    case closedTransport

    var errorDescription: String? {
        switch self {
        case .emptyTerminalType: return "Terminal type must not be empty."
        case .nonPositiveColumns: return "Terminal columns must be greater than zero."
        case .nonPositiveRows: return "Terminal rows must be greater than zero."
        case .negativePixelWidth: return "Terminal pixel width must not be negative."
        case .negativePixelHeight: return "Terminal pixel height must not be negative."
        case .closedTransport: return "The SSH PTY transport is no longer active."
        }
    }
}

/// Generic terminal dimensions, deliberately independent of any view geometry.
struct SSHPTYDimensions: Sendable, Equatable {
    let columns: Int
    let rows: Int
    let pixelWidth: Int
    let pixelHeight: Int

    init(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) throws {
        guard columns > 0 else { throw SSHPTYConfigurationError.nonPositiveColumns }
        guard rows > 0 else { throw SSHPTYConfigurationError.nonPositiveRows }
        guard pixelWidth >= 0 else { throw SSHPTYConfigurationError.negativePixelWidth }
        guard pixelHeight >= 0 else { throw SSHPTYConfigurationError.negativePixelHeight }
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Parameters for a generic SSH pseudo-terminal request.
struct SSHPTYConfiguration: Sendable, Equatable {
    let terminalType: String
    let dimensions: SSHPTYDimensions

    init(
        terminalType: String = "xterm-256color",
        columns: Int = 80,
        rows: Int = 24,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0
    ) throws {
        let normalizedTerminalType = terminalType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTerminalType.isEmpty else { throw SSHPTYConfigurationError.emptyTerminalType }
        self.terminalType = normalizedTerminalType
        dimensions = try SSHPTYDimensions(
            columns: columns,
            rows: rows,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}

/// Raw output from a PTY. Citadel preserves stdout/stderr events separately;
/// SSH servers commonly merge them once a PTY is allocated, so callers must
/// not assume stderr will always be distinct.
enum SSHPTYEvent: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
}

actor SSHPTYTransportLifetime {
    private var active = true

    func invalidate() {
        active = false
    }

    func requireActive() throws {
        guard active else { throw SSHPTYConfigurationError.closedTransport }
    }
}

/// A demand-driven adapter over Citadel's output sequence. Unlike an
/// `AsyncThrowingStream` producer task, this introduces no second in-memory
/// transcript or lossy buffering policy: each next event is read only when the
/// caller advances the sequence.
struct SSHPTYEventSequence: AsyncSequence, @unchecked Sendable {
    typealias Element = SSHPTYEvent

    private let output: PTYUncheckedSendable<TTYOutput>?
    private let testStream: AsyncThrowingStream<SSHPTYEvent, Error>?

    init(output: TTYOutput) {
        self.output = PTYUncheckedSendable(output)
        testStream = nil
    }

    init(testStream: AsyncThrowingStream<SSHPTYEvent, Error>) {
        output = nil
        self.testStream = testStream
    }

    func makeAsyncIterator() -> Iterator {
        if let output {
            return Iterator(storage: .tty(output.value.makeAsyncIterator()))
        }
        if let testStream {
            return Iterator(storage: .stream(testStream.makeAsyncIterator()))
        }
        let emptyStream = AsyncThrowingStream<SSHPTYEvent, Error> { $0.finish() }
        return Iterator(storage: .stream(emptyStream.makeAsyncIterator()))
    }

    struct Iterator: AsyncIteratorProtocol {
        fileprivate enum Storage {
            case tty(TTYOutput.AsyncIterator)
            case stream(AsyncThrowingStream<SSHPTYEvent, Error>.AsyncIterator)
        }

        private var storage: Storage

        fileprivate init(storage: Storage) {
            self.storage = storage
        }

        mutating func next() async throws -> SSHPTYEvent? {
            switch storage {
            case .stream(var iterator):
                let event = try await iterator.next()
                storage = .stream(iterator)
                return event
            case .tty(var iterator):
                guard let event = try await iterator.next() else { return nil }
                storage = .tty(iterator)
                switch event {
                case .stdout(let buffer): return .stdout(Data(buffer.readableBytesView))
                case .stderr(let buffer): return .stderr(Data(buffer.readableBytesView))
                }
            }
        }
    }
}

/// Raw byte transport for a single interactive SSH PTY channel.
///
/// The transport has no terminal emulator, text decoder, line buffering, or
/// reconnect policy. Its lifetime is limited to the `SSHSession.withPTY`
/// operation that created it.
struct SSHPTYTransport: Sendable {
    private let eventSequence: SSHPTYEventSequence
    private let lifetime: SSHPTYTransportLifetime
    private let writeBytes: @Sendable (Data) async throws -> Void
    private let changeSize: @Sendable (SSHPTYDimensions) async throws -> Void

    init(
        eventSequence: SSHPTYEventSequence,
        lifetime: SSHPTYTransportLifetime,
        writeBytes: @escaping @Sendable (Data) async throws -> Void,
        changeSize: @escaping @Sendable (SSHPTYDimensions) async throws -> Void
    ) {
        self.eventSequence = eventSequence
        self.lifetime = lifetime
        self.writeBytes = writeBytes
        self.changeSize = changeSize
    }

    func events() -> SSHPTYEventSequence {
        eventSequence
    }

    func write(_ data: Data) async throws {
        try await lifetime.requireActive()
        try await writeBytes(data)
    }

    func resize(
        columns: Int,
        rows: Int,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0
    ) async throws {
        try await lifetime.requireActive()
        try await changeSize(
            SSHPTYDimensions(
                columns: columns,
                rows: rows,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        )
    }
}

/// Citadel's NIO-backed stream and writer are event-loop safe but do not
/// express Sendability. This wrapper is kept entirely at the PTY boundary.
struct PTYUncheckedSendable<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}
