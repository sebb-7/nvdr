import Foundation
import Observation

/// Drives the bridge end-to-end:
///   iOS BT keyboard → BridgeClient → SSH → `nvdr --ipc` → relay → slave NVDA
///                     ←——— stdout (speak/cancel/state) ←———————————————————
///
/// Lifecycle is intentionally close to the Python add-on's `NvdrBridge` in
/// `addon/globalPlugins/nvdrBridge/__init__.py`: connect on `start`, parse
/// line-oriented IPC, surface a connected/passthrough toggle to the UI.
@Observable
@MainActor
final class BridgeClient {
    enum Status: Equatable, Sendable {
        case idle
        case connecting
        case authenticating
        case ready
        case nvdaNotConnected
        case disconnected(reason: String)
        case failed(message: String)
    }

    private(set) var status: Status = .idle
    private(set) var lastSpeech: String = ""
    private(set) var log: [String] = []

    /// User-controlled toggle (NVDA add-on calls this "passthrough"). When
    /// `true`, BT keystrokes flow to the slave; when `false`, they're handled
    /// locally. Independent of `status`: the connection can be ready while
    /// forwarding is off. Defaults to on — most sessions want forwarding the
    /// moment they connect, and the user can flip it off when they need to
    /// interact with the iPhone normally.
    var forwardingEnabled: Bool = true {
        didSet {
            if !forwardingEnabled, oldValue {
                send(.releaseAll)
            }
        }
    }

    private var driver: Task<Void, Never>?
    private var commandContinuation: AsyncStream<IPCCommand>.Continuation?
    private let speech: SpeechOutput

    init(speech: SpeechOutput) {
        self.speech = speech
    }

    func start(_ settings: AppSettings) {
        stop()
        let host = settings.sshHost
        let port = settings.sshPort
        let user = settings.sshUser
        let remote = settings.remoteCommand()

        guard !host.isEmpty, !user.isEmpty, !settings.channel.isEmpty else {
            status = .failed(message: "Set SSH host, user, and channel in Settings.")
            return
        }

        let authentication: SSHAuthenticationConfiguration
        switch settings.sshAuthMode {
        case .password:
            authentication = .password(settings.sshPassword)
        case .privateKey:
            authentication = .privateKey(
                pem: settings.sshPrivateKeyPEM,
                passphrase: settings.sshPrivateKeyPassphrase
            )
        }
        let sessionConfiguration = SSHSessionConfiguration(
            host: host,
            port: port,
            username: user,
            authentication: authentication
        )

        // Validate and summarize authentication up front so failures are
        // immediate and diagnostics still include the offered key fingerprint.
        let summary: SSHAuthenticationSummary
        do {
            summary = try SSHSession.authenticationSummary(for: sessionConfiguration)
        } catch {
            status = .failed(message: "auth: \(error.localizedDescription)")
            appendLog("auth setup failed: \(error.localizedDescription)")
            return
        }

        let (stream, cont) = AsyncStream<IPCCommand>.makeStream()
        commandContinuation = cont
        status = .connecting
        appendLog("connecting to \(user)@\(host):\(port) using \(summary.kind)")
        if let fp = summary.fingerprint {
            appendLog("offered pubkey fingerprint: \(fp)")
            appendLog("server-side check: ssh-keygen -lf ~/.ssh/authorized_keys | grep \(fp.replacingOccurrences(of: "/", with: "\\/"))")
        }

        driver = Task { [weak self] in
            await self?.runDriver(
                configuration: sessionConfiguration,
                remote: remote, commandStream: stream
            )
        }
    }

    func stop() {
        send(.quit)
        commandContinuation?.finish()
        commandContinuation = nil
        driver?.cancel()
        driver = nil
        forwardingEnabled = false
        if case .ready = status { status = .disconnected(reason: "stopped") }
    }

    /// Send an IPC command to the bridge. Silently dropped if not connected —
    /// matches the add-on's behavior (it logs a warning and moves on).
    func send(_ command: IPCCommand) {
        commandContinuation?.yield(command)
    }

    func sendKey(vk: UInt16, pressed: Bool) {
        send(.key(vk: vk, pressed: pressed))
    }

    // -- Speech forwarding ---------------------------------------------------

    func previewSpeech(_ sample: String? = nil) {
        let speech = self.speech
        Task {
            if let sample {
                await speech.preview(sample)
            } else {
                await speech.preview()
            }
        }
    }

    func setSpeechRate(_ rate: Float) {
        let speech = self.speech
        Task { await speech.setRate(rate) }
    }

    func setSpeechVoice(_ identifier: String?) {
        let speech = self.speech
        Task { await speech.setVoice(identifier: identifier) }
    }

    nonisolated private func runDriver(
        configuration: SSHSessionConfiguration,
        remote: String, commandStream: AsyncStream<IPCCommand>
    ) async {
        let session = SSHSession(configuration: configuration)
        do {
            await setStatus(.authenticating)
            try await session.connect()
            await appendLogAsync("ssh authenticated; spawning: \(remote)")

            try await session.withExec(remote) { transport in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await cmd in commandStream {
                            let line = Data((cmd.line + "\n").utf8)
                            do {
                                try await transport.write(line)
                            } catch {
                                await self.appendLogAsync("stdin write failed: \(error)")
                                return
                            }
                        }
                    }
                    group.addTask {
                        // stdout chunks arrive at arbitrary boundaries — split
                        // by newline and feed each line to the IPC parser.
                        var pending = ""
                        for try await event in transport.events() {
                            switch event {
                            case .stdout(let data):
                                let s = String(decoding: data, as: UTF8.self)
                                pending += s
                                while let nl = pending.firstIndex(of: "\n") {
                                    let line = String(pending[..<nl])
                                    pending.removeSubrange(...nl)
                                    await self.handle(IPCParser.parse(line))
                                }
                            case .stderr(let data):
                                let s = String(decoding: data, as: UTF8.self)
                                for chunk in s.split(separator: "\n", omittingEmptySubsequences: false) {
                                    let line = String(chunk)
                                    if !line.isEmpty {
                                        await self.appendLogAsync("nvdr: \(line)")
                                    }
                                }
                            }
                        }
                        if !pending.isEmpty {
                            await self.handle(IPCParser.parse(pending))
                        }
                    }
                    try await group.waitForAll()
                }
            }
            try? await session.close()
            await setStatus(.disconnected(reason: "remote process exited"))
        } catch is CancellationError {
            try? await session.close()
            await setStatus(.disconnected(reason: "stopped"))
        } catch {
            try? await session.close()
            let msg = "\(error)"
            await appendLogAsync("driver error: \(msg)")
            // The bundled SSH library (Citadel + swift-nio-ssh) only signs
            // RSA with SHA-1 (`ssh-rsa`). OpenSSH 8.7+ disables that by
            // default — `authorized_keys` will be a perfect match and the
            // server still rejects you. Surface the actionable fix instead
            // of the opaque "allAuthenticationOptionsFailed".
            if case .privateKey = configuration.authentication,
               msg.contains("allAuthenticationOptionsFailed") || msg.contains("authentication") {
                await appendLogAsync(
                    "hint: if your key is RSA, modern sshd (8.7+) rejects ssh-rsa SHA-1. " +
                    "Generate ed25519: `ssh-keygen -t ed25519` and add the .pub to authorized_keys. " +
                    "Or add `PubkeyAcceptedAlgorithms +ssh-rsa` to sshd_config."
                )
            }
            await setStatus(.failed(message: msg))
        }
    }

    nonisolated private func handle(_ event: IPCEvent) async {
        switch event {
        case .speak(let text):
            await setLastSpeech(text)
            await speech.speak(text)
        case .cancel:
            await speech.cancel()
        case .state(let s):
            if let mapped = Self.map(state: s) {
                await setStatus(mapped)
            }
            if s == .disconnected || s == .quit || s == .nvdaNotConnected {
                await turnForwardingOff()
            }
        case .error(let msg):
            await appendLogAsync("relay error: \(msg)")
        case .unknown(let line):
            await appendLogAsync("unknown line: \(line)")
        }
    }

    private func setLastSpeech(_ text: String) {
        lastSpeech = text
    }

    private func turnForwardingOff() {
        if forwardingEnabled { forwardingEnabled = false }
    }

    nonisolated private static func map(state: BridgeState) -> Status? {
        switch state {
        case .connecting: return .connecting
        case .ready: return .ready
        case .nvdaNotConnected: return .nvdaNotConnected
        case .disconnected: return .disconnected(reason: "relay")
        case .quit: return .disconnected(reason: "quit")
        case .unknown: return nil
        }
    }

    private func setStatus(_ s: Status) {
        status = s
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    nonisolated private func appendLogAsync(_ line: String) async {
        await appendLog(line)
    }
}
