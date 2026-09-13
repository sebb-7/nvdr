import Foundation
import Observation

/// Connection lifecycle for one Mac Remote Control screen.
///
/// Ready means FarRelay Host advertised VoiceOver operations and
/// `voiceover.status` reported a usable runtime. `platform == macOS` is not enough.
enum MacRemoteControlPhase: Equatable, Sendable {
    case disconnected
    case connecting
    case checkingCapabilities
    case unsupportedHost
    case unavailable
    case ready
    case failed(String)

    var statusText: String {
        switch self {
        case .disconnected:
            "Disconnected"
        case .connecting:
            "Connecting"
        case .checkingCapabilities:
            "Checking VoiceOver support"
        case .unsupportedHost:
            "This computer's FarRelay Host does not support VoiceOver Remote Control."
        case .unavailable:
            "VoiceOver is not ready on this Mac."
        case .ready:
            "Ready"
        case .failed(let message):
            "Failed: \(message)"
        }
    }

    var controlsEnabled: Bool { self == .ready }

    var isSessionOpen: Bool {
        switch self {
        case .connecting, .checkingCapabilities, .unsupportedHost, .unavailable, .ready:
            true
        case .disconnected, .failed:
            false
        }
    }
}

/// Opens one long-lived structured Host client for a Remote Control session.
protocol MacRemoteControlConnectionFactory: Sendable {
    func openSession(
        configuration: SSHSessionConfiguration,
        hostCommand: String,
        handle: @escaping @Sendable (any HostClientProtocol) async throws -> Void
    ) async throws
}

struct ProductionMacRemoteControlConnectionFactory: MacRemoteControlConnectionFactory {
    func openSession(
        configuration: SSHSessionConfiguration,
        hostCommand: String,
        handle: @escaping @Sendable (any HostClientProtocol) async throws -> Void
    ) async throws {
        let session = SSHSession(configuration: configuration)
        try await session.connect()
        do {
            try await FarRelayHostConnection.withClient(session: session, command: hostCommand) { client in
                try await handle(client)
            }
            try await session.close()
        } catch {
            try? await session.close()
            throw error
        }
    }
}

/// Authority for the Mac Remote Control screen. Not a terminal and not NVDA Remote.
@Observable
@MainActor
final class MacRemoteControlSession {
    static let requiredVoiceOverOperations = [
        "voiceover.status",
        "voiceover.move",
        "voiceover.press",
        "voiceover.state",
    ]

    private(set) var phase: MacRemoteControlPhase = .disconnected
    private(set) var activeProfile: HostProfile?
    private(set) var usedHostCommand: String?
    private(set) var usedConfiguration: SSHSessionConfiguration?
    private(set) var voiceOverStatus: VoiceOverStatus?
    private(set) var voiceOverState: VoiceOverState?
    private(set) var lastCompletedAction: MacRemoteControlAction?
    private(set) var lastActionError: String?
    private(set) var lastStateRefreshError: String?

    private let connectionFactory: any MacRemoteControlConnectionFactory
    private var client: (any HostClientProtocol)?
    private var generation = 0
    private var runTask: Task<Void, Never>?
    private var actionQueue = Task<Void, Never> {}

    init(
        connectionFactory: any MacRemoteControlConnectionFactory = ProductionMacRemoteControlConnectionFactory()
    ) {
        self.connectionFactory = connectionFactory
    }

    isolated deinit {
        runTask?.cancel()
    }

    var controlsEnabled: Bool { phase.controlsEnabled }

    var statusText: String { phase.statusText }

    var voiceOverStatusText: String {
        voiceOverStatus?.runtimeSummary ?? "VoiceOver status has not been fetched."
    }

    var lastSpokenPhraseText: String? { nonempty(voiceOverState?.lastSpokenPhrase) }
    var voiceOverCursorText: String? { nonempty(voiceOverState?.voiceOverCursorText) }
    var keyboardCursorText: String? { nonempty(voiceOverState?.keyboardCursorText) }

    var hasDisplayedVoiceOverState: Bool {
        lastSpokenPhraseText != nil || voiceOverCursorText != nil || keyboardCursorText != nil
    }

    func connect(settings: AppSettings, profile: HostProfile) async {
        guard profile.exposesMacRemoteControl else {
            await disconnectPreservingState()
            phase = .failed("Remote Control is available only for macOS computers.")
            return
        }
        guard let configuration = settings.sshSessionConfiguration(for: profile) else {
            await disconnectPreservingState()
            phase = .failed("Select a complete macOS computer with saved credentials before connecting.")
            return
        }
        await connect(profile: profile, configuration: configuration)
    }

    func connect(profile: HostProfile, configuration: SSHSessionConfiguration) async {
        await disconnectPreservingState()
        guard profile.exposesMacRemoteControl else {
            phase = .failed("Remote Control is available only for macOS computers.")
            return
        }
        guard profile.isConnectionReady else {
            phase = .failed("Select a complete macOS computer before connecting.")
            return
        }
        do {
            _ = try SSHSession.authenticationSummary(for: configuration)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        generation &+= 1
        let generation = generation
        activeProfile = profile
        usedConfiguration = configuration
        usedHostCommand = FarRelayHostConnection.resolvedCommand(profile.farRelayHostCommand)
        lastActionError = nil
        lastStateRefreshError = nil
        lastCompletedAction = nil
        phase = .connecting

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.connectionFactory.openSession(
                    configuration: configuration,
                    hostCommand: FarRelayHostConnection.resolvedCommand(profile.farRelayHostCommand)
                ) { [weak self] client in
                    await self?.serve(client, generation: generation)
                }
                await self.handleSessionEnded(generation: generation)
            } catch is CancellationError {
                await self.handleSessionEnded(generation: generation)
            } catch {
                await self.failIfCurrent(generation, error)
            }
        }
        await waitUntilSettled(generation: generation)
    }

    func disconnect() async {
        await disconnectPreservingState()
        phase = .disconnected
    }

    func perform(_ action: MacRemoteControlAction) async {
        let previous = actionQueue
        let current = Task { [weak self] in
            await previous.value
            await self?.execute(action)
        }
        actionQueue = current
        await current.value
    }

    private func disconnectPreservingState() async {
        generation &+= 1
        client = nil
        actionQueue = Task {}
        runTask?.cancel()
        await runTask?.value
        runTask = nil
    }

    private func serve(_ client: any HostClientProtocol, generation: Int) async {
        guard isCurrent(generation) else { return }
        self.client = client
        phase = .checkingCapabilities
        do {
            let capabilities = try await client.capabilities()
            guard isCurrent(generation) else { return }
            let missing = Self.requiredVoiceOverOperations.filter { !capabilities.operations.contains($0) }
            if !missing.isEmpty {
                phase = .unsupportedHost
                await waitForDisconnectOrClientLoss(client, generation: generation)
                return
            }

            let status = try await client.voiceOverStatus()
            guard isCurrent(generation) else { return }
            voiceOverStatus = status
            guard status.isUsableForRemoteControl else {
                phase = .unavailable
                await waitForDisconnectOrClientLoss(client, generation: generation)
                return
            }

            do {
                voiceOverState = try await client.voiceOverState()
                lastStateRefreshError = nil
            } catch {
                lastStateRefreshError = stateRefreshMessage(error)
            }
            guard isCurrent(generation) else { return }
            phase = .ready
            await waitForDisconnectOrClientLoss(client, generation: generation)
        } catch {
            guard isCurrent(generation) else { return }
            phase = .failed(connectFailureMessage(error))
        }
    }

    private func execute(_ action: MacRemoteControlAction) async {
        guard phase == .ready, let client else { return }
        let generation = generation
        lastActionError = nil
        lastStateRefreshError = nil
        do {
            switch action {
            case .refreshState:
                let state = try await client.voiceOverState()
                guard isCurrent(generation), phase == .ready else { return }
                voiceOverState = state
                lastCompletedAction = action
            case .activate:
                _ = try await client.voiceOverPress()
                guard isCurrent(generation), phase == .ready else { return }
                lastCompletedAction = action
                await refreshStateAfterSuccessfulAction(client, generation: generation)
            default:
                guard let direction = action.moveDirection else { return }
                _ = try await client.voiceOverMove(direction)
                guard isCurrent(generation), phase == .ready else { return }
                lastCompletedAction = action
                await refreshStateAfterSuccessfulAction(client, generation: generation)
            }
        } catch {
            guard isCurrent(generation) else { return }
            lastActionError = "\(action.buttonTitle) failed: \(error.localizedDescription)"
        }
    }

    private func refreshStateAfterSuccessfulAction(
        _ client: any HostClientProtocol,
        generation: Int
    ) async {
        do {
            let state = try await client.voiceOverState()
            guard isCurrent(generation) else { return }
            voiceOverState = state
            lastStateRefreshError = nil
        } catch {
            guard isCurrent(generation) else { return }
            lastStateRefreshError = stateRefreshMessage(error)
        }
    }

    private func waitForDisconnectOrClientLoss(
        _ client: any HostClientProtocol,
        generation: Int
    ) async {
        await FirstCompleted.wait {
            await client.waitUntilUnavailable()
        } or: { @MainActor [weak self] in
            guard let self else { return }
            while self.isCurrent(generation) {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func handleSessionEnded(generation: Int) async {
        guard isCurrent(generation) else { return }
        client = nil
        runTask = nil
        switch phase {
        case .ready, .connecting, .checkingCapabilities:
            phase = .failed("The FarRelay Host connection closed.")
        case .unsupportedHost, .unavailable, .failed, .disconnected:
            break
        }
    }

    private func failIfCurrent(_ generation: Int, _ error: Error) async {
        guard isCurrent(generation) else { return }
        client = nil
        runTask = nil
        phase = .failed(connectFailureMessage(error))
    }

    private func waitUntilSettled(generation: Int) async {
        for _ in 0..<2_000 {
            if !isCurrent(generation) || isSettled { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private var isSettled: Bool {
        switch phase {
        case .ready, .unavailable, .unsupportedHost, .failed, .disconnected:
            true
        case .connecting, .checkingCapabilities:
            false
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation
    }

    private func connectFailureMessage(_ error: Error) -> String {
        if let error = error as? HostClientError {
            return error.localizedDescription
        }
        if error is SSHAuthenticationError {
            return error.localizedDescription
        }
        return "Unable to start Remote Control. Check the host, network, and credentials."
    }

    private func stateRefreshMessage(_ error: Error) -> String {
        "Unable to refresh VoiceOver state: \(error.localizedDescription)"
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Completes when the first of two waits finishes. The loser is not cancelled
/// here; Remote Control then closes the Host client, which unblocks it.
private struct FirstCompleted: Sendable {
    static func wait(
        _ first: @escaping @Sendable () async -> Void,
        or second: @escaping @Sendable () async -> Void
    ) async {
        let gate = ResumeOnce()
        await withCheckedContinuation { continuation in
            Task {
                await first()
                gate.resume(continuation)
            }
            Task {
                await second()
                gate.resume(continuation)
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume()
    }
}
