import Darwin
import Foundation

/// A private, same-user Unix-domain endpoint. It is deliberately not a TCP,
/// Bonjour, LAN, or WAN listener. The bundled SSH helper is the only intended
/// client and merely forwards its authenticated stdio channel here.
@MainActor
final class MacHostSocketServer {
    static let endpointURL: URL = URL.homeDirectory
        .appending(path: "Library/Application Support/FarRelay", directoryHint: .isDirectory)
        .appending(path: "farrelay-host.sock")

    private let listener: FileHandle
    private let onLine: @Sendable (Int32, String, @escaping @Sendable (String) -> Void) -> Void
    private let onClientClosed: @Sendable (Int32) -> Void
    private let lock = NSLock()
    private var clients: [Int32: MacHostSocketClient] = [:]

    init(
        onLine: @escaping @Sendable (Int32, String, @escaping @Sendable (String) -> Void) -> Void,
        onClientClosed: @escaping @Sendable (Int32) -> Void = { _ in }
    ) throws {
        self.onLine = onLine
        self.onClientClosed = onClientClosed
        let directory = Self.endpointURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: Self.endpointURL)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(Self.endpointURL.path(percentEncoded: false).utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw CocoaError(.fileWriteInvalidFileName)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, chmod(Self.endpointURL.path(percentEncoded: false), 0o600) == 0, listen(descriptor, 8) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            close(descriptor)
            try? FileManager.default.removeItem(at: Self.endpointURL)
            throw error
        }
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        listener = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        listener.readabilityHandler = { [weak self] _ in
            Task { @MainActor in self?.acceptAvailableClients() }
        }
    }

    deinit {
        // `deinit` is nonisolated even for a main-actor type. The app-owned
        // service calls `stop()` for normal shutdown (including control-lease
        // revocation); deinitialization only closes this server's own endpoint.
        listener.readabilityHandler = nil
        listener.closeFile()
        try? FileManager.default.removeItem(at: Self.endpointURL)
    }

    func stop() {
        listener.readabilityHandler = nil
        lock.lock()
        let currentClients = clients.values
        clients.removeAll()
        lock.unlock()
        currentClients.forEach { $0.close() }
        listener.closeFile()
        try? FileManager.default.removeItem(at: Self.endpointURL)
    }

    private func acceptAvailableClients() {
        while true {
            let descriptor = accept(listener.fileDescriptor, nil, nil)
            if descriptor < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            var userID: uid_t = 0
            var groupID: gid_t = 0
            guard getpeereid(descriptor, &userID, &groupID) == 0, userID == getuid() else {
                close(descriptor)
                continue
            }
            let client = MacHostSocketClient(descriptor: descriptor, onLine: onLine) { [weak self] descriptor in
                Task { @MainActor in self?.removeClient(descriptor) }
            }
            lock.lock()
            clients[descriptor] = client
            lock.unlock()
        }
    }

    private func removeClient(_ descriptor: Int32) {
        lock.lock()
        clients.removeValue(forKey: descriptor)
        lock.unlock()
        onClientClosed(descriptor)
    }
}

@MainActor
private final class MacHostSocketClient {
    private let handle: FileHandle
    private let onLine: @Sendable (Int32, String, @escaping @Sendable (String) -> Void) -> Void
    private let onClose: @Sendable (Int32) -> Void
    private let lock = NSLock()
    private var buffer = Data()

    init(
        descriptor: Int32,
        onLine: @escaping @Sendable (Int32, String, @escaping @Sendable (String) -> Void) -> Void,
        onClose: @escaping @Sendable (Int32) -> Void
    ) {
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.onLine = onLine
        self.onClose = onClose
        handle.readabilityHandler = { [weak self] _ in
            Task { @MainActor in self?.readAvailableData() }
        }
    }

    func close() {
        handle.readabilityHandler = nil
        handle.closeFile()
    }

    private func readAvailableData() {
        let data = handle.availableData
        guard !data.isEmpty else {
            close()
            onClose(handle.fileDescriptor)
            return
        }
        lock.lock()
        buffer.append(data)
        guard buffer.count <= MacHostProtocol.maximumFrameBytes else {
            lock.unlock()
            close()
            onClose(handle.fileDescriptor)
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            let text = String(decoding: line, as: UTF8.self)
            onLine(handle.fileDescriptor, text) { [weak self] response in
                Task { @MainActor in self?.send(response) }
            }
        }
        lock.unlock()
    }

    private func send(_ response: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !response.utf8.isEmpty, response.utf8.count <= MacHostProtocol.maximumFrameBytes else { return }
        do { try handle.write(contentsOf: Data(response.utf8) + Data([0x0A])) }
        catch { close(); onClose(handle.fileDescriptor) }
    }
}
