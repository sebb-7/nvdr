import Foundation
import Observation

private actor SSHOperationCompletionBox {
    private var stored = SSHConnectedOperationCompletion.unexpectedlyEnded

    func set(_ completion: SSHConnectedOperationCompletion) {
        stored = completion
    }

    func value() -> SSHConnectedOperationCompletion {
        stored
    }
}

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
        case reconnecting(attempt: Int)
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
                inputState.reset()
            }
        }
    }

    private var driver: Task<Void, Never>?
    private var connectionSupervisor: SSHConnectionSupervisor<SSHSession>?
    private var commandContinuation: AsyncStream<IPCCommand>.Continuation?
    private var commandChannelID: UUID?
    private var inputReady = false
    private var inputState = SSHInputState()
    private var driverGeneration = 0
    private let speech: SpeechOutput

    init(speech: SpeechOutput) {
        self.speech = speech
    }

    func start(_ settings: AppSettings) {
        stop()
        driverGeneration += 1
        let generation = driverGeneration
        let host = settings.sshHost
        let port = settings.sshPort
        let user = settings.sshUser
        let remote = settings.remoteCommand()

        guard !host.isEmpty, !user.isEmpty, !settings.channel.isEmpty else {
            status = .failed(message: "Set SSH host, user, and channel in Settings.")
            return
        }

        let sessionConfiguration = settings.sshSessionConfiguration()

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

        status = .connecting
        appendLog("connecting to \(user)@\(host):\(port) using \(summary.kind)")
        if let fp = summary.fingerprint {
            appendLog("offered pubkey fingerprint: \(fp)")
            appendLog("server-side check: ssh-keygen -lf ~/.ssh/authorized_keys | grep \(fp.replacingOccurrences(of: "/", with: "\\/"))")
        }

        driver = Task { [weak self] in
            await self?.runDriver(
                configuration: sessionConfiguration,
                remote: remote,
                generation: generation
            )
        }
    }

    func stop() {
        driverGeneration += 1
        let activeSupervisor = connectionSupervisor
        connectionSupervisor = nil
        forwardingEnabled = false
        send(.quit)
        commandContinuation?.finish()
        commandContinuation = nil
        commandChannelID = nil
        inputReady = false
        inputState.reset()
        driver?.cancel()
        driver = nil
        Task { await activeSupervisor?.stop() }
        if case .idle = status { return }
        status = .disconnected(reason: "stopped")
    }

    /// Send an IPC command to the bridge. Silently dropped if not connected —
    /// matches the add-on's behavior (it logs a warning and moves on).
    func send(_ command: IPCCommand) {
        commandContinuation?.yield(command)
    }

    func sendKey(vk: UInt16, pressed: Bool) {
        guard forwardingEnabled, inputReady, let commandContinuation else { return }
        guard let command = inputState.command(forKey: vk, pressed: pressed) else { return }
        commandContinuation.yield(command)
    }

    /// Read-only input readiness for semantic adapters. This never changes
    /// forwarding state or attempts to establish the NVDA input channel.
    var isInputForwardingReady: Bool {
        forwardingEnabled && inputReady
    }

    private func register(
        supervisor: SSHConnectionSupervisor<SSHSession>,
        generation: Int
    ) -> Bool {
        guard driverGeneration == generation else { return false }
        connectionSupervisor = supervisor
        return true
    }

    private func unregister(
        supervisor: SSHConnectionSupervisor<SSHSession>,
        generation: Int
    ) {
        guard driverGeneration == generation, connectionSupervisor === supervisor else { return }
        connectionSupervisor = nil
    }

    private func openCommandChannel() -> (UUID, AsyncStream<IPCCommand>) {
        commandContinuation?.finish()
        let (stream, continuation) = AsyncStream<IPCCommand>.makeStream()
        let id = UUID()
        commandChannelID = id
        commandContinuation = continuation
        inputReady = false
        inputState.reset()
        return (id, stream)
    }

    private func activateCommandChannel(id: UUID) {
        guard commandChannelID == id else { return }
        inputState.reset()
        inputReady = true
    }

    private func invalidateCommandChannel(id: UUID) {
        guard commandChannelID == id else { return }
        inputReady = false
        inputState.reset()
        commandContinuation?.finish()
        commandContinuation = nil
        commandChannelID = nil
    }

    private func disconnectInputChannel() {
        inputReady = false
        inputState.reset()
        commandContinuation?.finish()
        commandContinuation = nil
        commandChannelID = nil
    }

    private func handleLifecycle(
        _ event: SSHConnectionLifecycleEvent,
        from supervisor: SSHConnectionSupervisor<SSHSession>,
        configuration: SSHSessionConfiguration,
        generation: Int
    ) {
        guard driverGeneration == generation, connectionSupervisor === supervisor else { return }
        switch event {
        case .connecting:
            status = .authenticating

        case .connected:
            appendLog("ssh authenticated; spawning the remote IPC operation")

        case .disconnected(let failure):
            disconnectInputChannel()
            appendLog("ssh disconnected: \(failure.message)")
            status = .disconnected(reason: failure.message)

        case .reconnecting(let attempt, let delay, let failure):
            disconnectInputChannel()
            appendLog(
                "reconnecting after \(delay) " +
                "(attempt \(attempt)): \(failure.message)"
            )
            status = .reconnecting(attempt: attempt)

        case .permanentlyFailed(let failure):
            disconnectInputChannel()
            appendLog("ssh session failed: \(failure.message)")
            if case .privateKey = configuration.authentication,
               failure.message.contains("allAuthenticationOptionsFailed") || failure.message.contains("authentication") {
                appendLog(
                    "hint: if your key is RSA, modern sshd (8.7+) rejects ssh-rsa SHA-1. " +
                    "Generate ed25519: `ssh-keygen -t ed25519` and add the .pub to authorized_keys. " +
                    "Or add `PubkeyAcceptedAlgorithms +ssh-rsa` to sshd_config."
                )
            }
            status = .failed(message: failure.message)

        case .stopped:
            disconnectInputChannel()
            if case .failed = status { return }
            status = .disconnected(reason: "stopped")
        }
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
        remote: String,
        generation: Int
    ) async {
        let supervisor = SSHConnectionSupervisor<SSHSession>(
            reconnectPolicy: configuration.reconnectPolicy
        ) {
            SSHSession(configuration: configuration)
        }
        guard await register(supervisor: supervisor, generation: generation) else {
            await supervisor.stop()
            return
        }
        let lifecycleTask = Task { [weak self] in
            for await event in supervisor.lifecycleEvents {
                await self?.handleLifecycle(
                    event,
                    from: supervisor,
                    configuration: configuration,
                    generation: generation
                )
            }
        }

        await supervisor.run { [weak self] session in
            guard let self else { throw CancellationError() }
            return try await self.runConnectedOperation(session: session, remote: remote)
        }

        lifecycleTask.cancel()
        await unregister(supervisor: supervisor, generation: generation)
    }

    nonisolated private func runConnectedOperation(
        session: SSHSession,
        remote: String
    ) async throws -> SSHConnectedOperationCompletion {
        let completion = SSHOperationCompletionBox()
        try await session.withExec(remote) { [weak self] transport in
            guard let self else { throw CancellationError() }
            await completion.set(try await self.consumeBridgeTransport(transport))
        }
        return await completion.value()
    }

    nonisolated private func consumeBridgeTransport(
        _ transport: SSHExecTransport
    ) async throws -> SSHConnectedOperationCompletion {
        let (channelID, commandStream) = await openCommandChannel()
        do {
            // New sessions always begin from a known remote input state. The
            // channel is not made writable to keyboard input until this has
            // been sent successfully.
            try await transport.write(Data((IPCCommand.releaseAll.line + "\n").utf8))
            await activateCommandChannel(id: channelID)

            let completion = try await withThrowingTaskGroup(
                of: SSHConnectedOperationCompletion.self
            ) { group in
                group.addTask {
                    for await command in commandStream {
                        try await transport.write(Data((command.line + "\n").utf8))
                    }
                    return SSHConnectedOperationCompletion.unexpectedlyEnded
                }
                group.addTask {
                    // stdout chunks arrive at arbitrary boundaries — split
                    // by newline and feed each line to the IPC parser.
                    var pending = ""
                    for try await event in transport.events() {
                        switch event {
                        case .stdout(let data):
                            pending += String(decoding: data, as: UTF8.self)
                            while let newline = pending.firstIndex(of: "\n") {
                                let line = String(pending[..<newline])
                                pending.removeSubrange(...newline)
                                let parsed = IPCParser.parse(line)
                                await self.handle(parsed, from: channelID)
                                if case .state(.quit) = parsed {
                                    return SSHConnectedOperationCompletion.completedIntentionally
                                }
                            }
                        case .stderr(let data):
                            for chunk in String(decoding: data, as: UTF8.self)
                                .split(separator: "\n", omittingEmptySubsequences: false) {
                                let line = String(chunk)
                                if !line.isEmpty {
                                    await self.appendLogAsync("nvdr: \(line)")
                                }
                            }
                        }
                    }
                    if !pending.isEmpty {
                        let parsed = IPCParser.parse(pending)
                        await self.handle(parsed, from: channelID)
                        if case .state(.quit) = parsed {
                            return SSHConnectedOperationCompletion.completedIntentionally
                        }
                    }
                    return SSHConnectedOperationCompletion.unexpectedlyEnded
                }
                guard let completion = try await group.next() else {
                    return SSHConnectedOperationCompletion.unexpectedlyEnded
                }
                await self.invalidateCommandChannel(id: channelID)
                group.cancelAll()
                return completion
            }
            return completion
        } catch {
            await invalidateCommandChannel(id: channelID)
            throw error
        }
    }

    nonisolated private func handle(_ event: IPCEvent, from channelID: UUID) async {
        guard await isCurrentCommandChannel(channelID) else { return }
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

    private func isCurrentCommandChannel(_ id: UUID) -> Bool {
        commandChannelID == id
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
