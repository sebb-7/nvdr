import Foundation
@preconcurrency import Citadel
import Crypto
import NIOCore
@preconcurrency import NIOSSH

/// Configuration for one generic SSH connection.
///
/// This type deliberately describes an SSH endpoint and authentication only.
/// It has no knowledge of application protocols or any command run after login.
struct SSHSessionConfiguration: Sendable {
    let host: String
    let port: Int
    let username: String
    let authentication: SSHAuthenticationConfiguration

    /// SSH host identities are trusted on first use and then pinned to the
    /// endpoint. Insecure acceptance exists only as an explicit override.
    var hostKeyPolicy: SSHHostKeyPolicy = .trustOnFirstUse

    /// Reconnect is intentionally disabled to preserve the existing behavior.
    /// A future policy can add bounded retry/backoff without changing callers.
    var reconnectPolicy: SSHReconnectPolicy = .never
}

enum SSHAuthenticationConfiguration: Sendable, Equatable {
    case password(String)
    case privateKey(pem: String, passphrase: String)
}

enum SSHReconnectPolicy: Sendable, Equatable {
    case never
    // TODO: Add keepalive and reconnect/backoff policies here.
}

struct SSHAuthenticationSummary: Sendable, Equatable {
    let kind: String
    let fingerprint: String?
}

enum SSHAuthenticationError: LocalizedError, Equatable {
    case missingKey
    case wrongKeyFormat(detected: String)
    case unsupportedKey(detail: String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Paste an OpenSSH private key in Settings."
        case .wrongKeyFormat(let detected):
            return "Key is not in OpenSSH format (looks like \(detected)). Convert with: `ssh-keygen -p -N '' -f <keyfile>` (to OpenSSH format) or generate a fresh ed25519 key with `ssh-keygen -t ed25519`."
        case .unsupportedKey(let detail):
            return "Key parse failed: \(detail)"
        }
    }
}

enum SSHSessionEvent: Sendable {
    case stdout(Data)
    case stderr(Data)
}

/// Generic transport for one SSH exec channel.
///
/// The event stream can be consumed once. It intentionally exposes bytes,
/// rather than text or line framing, so callers can implement IPC, terminal,
/// or another protocol without the SSH layer making assumptions about it.
struct SSHExecTransport: Sendable {
    private let eventStream: AsyncThrowingStream<SSHSessionEvent, Error>
    private let writeBytes: @Sendable (Data) async throws -> Void

    fileprivate init(
        eventStream: AsyncThrowingStream<SSHSessionEvent, Error>,
        writeBytes: @escaping @Sendable (Data) async throws -> Void
    ) {
        self.eventStream = eventStream
        self.writeBytes = writeBytes
    }

    func events() -> AsyncThrowingStream<SSHSessionEvent, Error> {
        eventStream
    }

    func write(_ data: Data) async throws {
        try await writeBytes(data)
    }
}

/// Reusable SSH connection/session layer used by app-specific protocols.
///
/// A session is owned and used by one task at a time. NIO channels are
/// event-loop-safe but are not formally Sendable, so the only unchecked
/// boundary is kept here, next to the code that establishes that invariant.
final class SSHSession {
    let configuration: SSHSessionConfiguration

    private var client: SSHClient?
    private let hostIdentityStore: SSHHostIdentityStore

    init(
        configuration: SSHSessionConfiguration,
        hostIdentityStore: SSHHostIdentityStore = UserDefaultsSSHHostIdentityStore()
    ) {
        self.configuration = configuration
        self.hostIdentityStore = hostIdentityStore
    }

    /// Parse and summarize authentication without opening a network
    /// connection. Callers can use this for validation and diagnostics.
    static func authenticationSummary(
        for configuration: SSHSessionConfiguration
    ) throws -> SSHAuthenticationSummary {
        try parseAuthentication(configuration).summary
    }

    func connect() async throws {
        guard client == nil else { return }

        let authentication = try Self.parseAuthentication(configuration).auth
        var algorithms = SSHAlgorithms()

        // Register the custom RSA SHA-2 implementations. Citadel's built-in
        // RSA path signs with SHA-1, which modern OpenSSH disables by default.
        algorithms.publicKeyAlgorihtms = .add([
            (RSASHA512PublicKey.self, RSASHA512Signature.self),
            (RSASHA256PublicKey.self, RSASHA256Signature.self),
        ])

        let hostKeyValidator: SSHHostKeyValidator
        switch configuration.hostKeyPolicy {
        case .trustOnFirstUse:
            hostKeyValidator = .custom(
                SSHTOFUHostKeyValidator(
                    endpoint: SSHHostEndpoint(host: configuration.host, port: configuration.port),
                    store: hostIdentityStore
                )
            )
        case .insecureAcceptAnything:
            hostKeyValidator = .acceptAnything()
        }

        switch configuration.reconnectPolicy {
        case .never:
            client = try await SSHClient.connect(
                host: configuration.host,
                port: configuration.port,
                authenticationMethod: authentication,
                hostKeyValidator: hostKeyValidator,
                reconnect: .never,
                algorithms: algorithms
            )
        }
    }

    /// Open one exec channel on the connected SSH client.
    ///
    /// The SSH client remains owned by this session so future callers can add
    /// multiple concurrent channels or long-lived session management without
    /// exposing Citadel/NIO implementation types.
    func withExec(
        _ command: String,
        operation: @escaping @Sendable (SSHExecTransport) async throws -> Void
    ) async throws {
        guard let client else { throw SSHSessionError.notConnected }
        try await client.withExec(command, perform: { @Sendable inbound, outbound in
            let transport = Self.makeTransport(inbound: inbound, outbound: outbound)
            try await operation(transport)
        })
    }

    /// Close is intentionally idempotent. A caller may use it from both its
    /// normal and cancellation/error cleanup paths.
    func close() async throws {
        guard let client else { return }
        self.client = nil
        try await client.close()
    }

    private struct ParsedAuthentication {
        let auth: SSHAuthenticationMethod
        let summary: SSHAuthenticationSummary
    }

    private static func parseAuthentication(
        _ configuration: SSHSessionConfiguration
    ) throws -> ParsedAuthentication {
        switch configuration.authentication {
        case .password(let password):
            return ParsedAuthentication(
                auth: .passwordBased(username: configuration.username, password: password),
                summary: SSHAuthenticationSummary(kind: "password", fingerprint: nil)
            )

        case .privateKey(let rawPEM, let rawPassphrase):
            let pem = rawPEM.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pem.isEmpty else { throw SSHAuthenticationError.missingKey }

            guard pem.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") else {
                throw SSHAuthenticationError.wrongKeyFormat(detected: detectFormat(pem))
            }

            let passphrase = rawPassphrase.isEmpty ? nil : Data(rawPassphrase.utf8)

            // Try Ed25519 first; its parser rejects other key types cleanly.
            if let key = try? Curve25519.Signing.PrivateKey(
                sshEd25519: pem,
                decryptionKey: passphrase
            ) {
                return ParsedAuthentication(
                    auth: .ed25519(username: configuration.username, privateKey: key),
                    summary: SSHAuthenticationSummary(
                        kind: "ssh-ed25519",
                        fingerprint: ed25519Fingerprint(publicKey: key.publicKey.rawRepresentation)
                    )
                )
            }

            // Preserve the custom RSA SHA-2 implementation used by the app.
            let parts: RSAOpenSSH.PrivateKeyComponents
            do {
                parts = try RSAOpenSSH.parse(pem: pem)
            } catch {
                throw SSHAuthenticationError.unsupportedKey(detail: "\(error.localizedDescription)")
            }
            let delegate = RSASHA2AuthDelegate(
                username: configuration.username,
                openSSHPrivateKeyPEM: pem
            )
            return ParsedAuthentication(
                auth: .custom(delegate),
                summary: SSHAuthenticationSummary(
                    kind: "rsa-sha2-512/256",
                    fingerprint: rsaFingerprint(n: parts.n, e: parts.e)
                )
            )
        }
    }

    private static func makeTransport(
        inbound: TTYOutput,
        outbound: TTYStdinWriter
    ) -> SSHExecTransport {
        let safeIn = SSHUncheckedSendable(inbound)
        let safeOut = SSHUncheckedSendable(outbound)
        let stream = AsyncThrowingStream<SSHSessionEvent, Error> { continuation in
            Task {
                do {
                    for try await event in safeIn.value {
                        switch event {
                        case .stdout(let buffer):
                            continuation.yield(.stdout(Data(buffer.readableBytesView)))
                        case .stderr(let buffer):
                            continuation.yield(.stderr(Data(buffer.readableBytesView)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return SSHExecTransport(eventStream: stream) { data in
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            try await safeOut.value.write(buffer)
        }
    }

    private static func rsaFingerprint(n: Data, e: Data) -> String {
        var blob = Data()
        func appendString(_ bytes: Data) {
            var len = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &len) { blob.append(contentsOf: $0) }
            blob.append(bytes)
        }
        func appendMPInt(_ bytes: Data) {
            var trimmed = bytes
            while trimmed.first == 0x00, trimmed.count > 1 { trimmed = trimmed.dropFirst() }
            var prefixed = Data()
            if let first = trimmed.first, first & 0x80 != 0 { prefixed.append(0x00) }
            prefixed.append(trimmed)
            appendString(prefixed)
        }
        appendString(Data("ssh-rsa".utf8))
        appendMPInt(e)
        appendMPInt(n)
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(b64)"
    }

    private static func ed25519Fingerprint(publicKey: Data) -> String {
        var blob = Data()
        let typeStr = "ssh-ed25519"
        var typeLen = UInt32(typeStr.utf8.count).bigEndian
        withUnsafeBytes(of: &typeLen) { blob.append(contentsOf: $0) }
        blob.append(contentsOf: typeStr.utf8)
        var keyLen = UInt32(publicKey.count).bigEndian
        withUnsafeBytes(of: &keyLen) { blob.append(contentsOf: $0) }
        blob.append(publicKey)
        let digest = SHA256.hash(data: blob)
        let b64 = Data(digest).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(b64)"
    }

    private static func detectFormat(_ pem: String) -> String {
        if pem.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") { return "PEM/PKCS#1 RSA" }
        if pem.hasPrefix("-----BEGIN EC PRIVATE KEY-----") { return "PEM/SEC1 ECDSA" }
        if pem.hasPrefix("-----BEGIN PRIVATE KEY-----") { return "PEM/PKCS#8" }
        if pem.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----") { return "PEM/PKCS#8 (encrypted)" }
        if pem.hasPrefix("-----BEGIN DSA PRIVATE KEY-----") { return "PEM/PKCS#1 DSA" }
        if pem.contains("PUBLIC KEY") { return "public key (you need the private key)" }
        return "unrecognized"
    }
}

enum SSHSessionError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected: return "SSH session is not connected."
        }
    }
}

/// NIO's channel and stream types are event-loop-safe, but do not currently
/// express that fact as Swift Sendable conformances. Keep this wrapper local
/// to the SSH transport boundary instead of spreading unchecked values into
/// protocol consumers.
private struct SSHUncheckedSendable<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}
