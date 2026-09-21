import Foundation
import Observation

@MainActor
@Observable
final class MacRemoteSession {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case controlGranted
        case controlBusy
        case failed(String)
    }

    private(set) var state: State = .disconnected
    private(set) var speechSubscriptionActive = false
    private(set) var keyboardForwardingActive = false
    private(set) var activeProfile: HostProfile?
    private let controllerID = UUID().uuidString.lowercased()

    @ObservationIgnored private var session: SSHSession?
    @ObservationIgnored private var client: FarRelayHostClient?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var speechGeneration: UUID?
    @ObservationIgnored private var lastSpeechSequence: UInt64 = 0
    @ObservationIgnored private let speech: SpeechOutput

    init(speech: SpeechOutput) { self.speech = speech }

    deinit { task?.cancel() }

    func connect(profile: HostProfile, credentials: HostProfileCredentials) {
        guard task == nil, profile.isMacRemoteEnabled else { return }
        activeProfile = profile
        state = .connecting
        let session = SSHSession(configuration: profile.sshSessionConfiguration(credentials: credentials))
        let didConnect: @MainActor @Sendable (FarRelayHostClient, Bool) -> Void = { [weak self] client, subscribed in
            self?.didConnect(client: client, subscription: subscribed)
        }
        let consumeEvents: @MainActor @Sendable (AsyncStream<MacRemoteHostEvent>) -> Void = { [weak self] events in
            self?.consume(events: events)
        }
        let didFail: @MainActor @Sendable (String) -> Void = { [weak self] message in
            self?.state = .failed(message)
            self?.keyboardForwardingActive = false
        }
        let didEnd: @MainActor @Sendable () -> Void = { [weak self] in
            self?.didEnd()
        }
        self.session = session
        task = Task {
            do {
                try await session.connect()
                try await session.withExec(profile.macRemoteHostCommand) { transport in
                    let client = FarRelayHostClient(transport: transport)
                    await client.start()
                    let subscription = try await client.subscribeToMacRemoteEvents([
                        "speech.utterance", "speech.cancel", "session.state", "controller.changed", "permission.changed",
                    ])
                    await didConnect(client, subscription.subscribed)
                    if subscription.subscribed {
                        let events = await client.macRemoteEvents()
                        await consumeEvents(events)
                    }
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(3600))
                    }
                    await client.close()
                }
            } catch is CancellationError {
                // Explicit Disconnect is already represented locally.
            } catch {
                await didFail(error.localizedDescription)
            }
            try? await session.close()
            await didEnd()
        }
    }

    func disconnect() {
        let client = client
        let session = session
        task?.cancel()
        eventTask?.cancel()
        task = nil
        self.client = nil
        self.session = nil
        generation = nil
        keyboardForwardingActive = false
        speechSubscriptionActive = false
        activeProfile = nil
        Task { await speech.cancel() }
        state = .disconnected
        Task {
            if let client { try? await client.releaseMacRemoteControl(controllerID: controllerID); await client.close() }
            try? await session?.close()
        }
    }

    func requestControl() {
        guard let client else { return }
        Task {
            do {
                let result = try await client.requestMacRemoteControl(controllerID: controllerID)
                if result.state == "granted", let generation = result.generation {
                    self.generation = generation
                    keyboardForwardingActive = true
                    state = .controlGranted
                } else {
                    keyboardForwardingActive = false
                    state = .controlBusy
                }
            } catch { didFail(error) }
        }
    }

    func releaseControl() {
        guard let client else { return }
        Task {
            try? await client.releaseMacRemoteControl(controllerID: controllerID)
            generation = nil
            keyboardForwardingActive = false
            state = .connected
        }
    }

    func emergencyStop() {
        guard let client else { return }
        Task {
            try? await client.emergencyStopMacRemote()
            generation = nil
            keyboardForwardingActive = false
            state = .connected
        }
    }

    func sendCombo(_ keys: [MacRemoteKey]) {
        Task {
            _ = await sendComboForRemoteIntent(keys)
        }
    }

    var remoteIntentGeneration: UInt64? { generation }

    var remoteIntentConnectionState: HostTarget.ConnectionState {
        if keyboardForwardingActive { return .ready }
        return switch state {
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected, .controlBusy: .unavailable("Mac Remote control has not been granted.")
        case .controlGranted: .unavailable("Mac Remote keyboard forwarding is unavailable.")
        case .failed(let message): .unavailable(message)
        }
    }

    func performMacRemoteKeyTransition(
        _ key: MacRemoteKey,
        pressed: Bool
    ) async -> RemoteIntentResult {
        guard let client, let generation, keyboardForwardingActive else {
            return .unavailable("Mac Remote control has not been granted.")
        }
        do {
            let result = try await client.sendMacRemoteKey(
                controllerID: controllerID,
                generation: generation,
                key: key,
                pressed: pressed
            )
            guard result.accepted else {
                await emergencyStopAfterInputFailure(using: client)
                return .failed("The Mac rejected remote input.")
            }
            return .performed
        } catch {
            await emergencyStopAfterInputFailure(using: client)
            didFail(error)
            return .failed(error.localizedDescription)
        }
    }

    func performMacRemoteAction(_ action: MacRemoteAction) async -> RemoteIntentResult {
        let keys: [MacRemoteKey] = switch action {
        case .nextItem: [.leftControl, .leftOption, .rightArrow]
        case .previousItem: [.leftControl, .leftOption, .leftArrow]
        case .activate: [.leftControl, .leftOption, .space]
        case .nextApplication: [.leftCommand, .tab]
        }
        return await sendComboForRemoteIntent(keys)
    }

    private func sendComboForRemoteIntent(_ keys: [MacRemoteKey]) async -> RemoteIntentResult {
        guard let client, let generation, keyboardForwardingActive else {
            return .unavailable("Mac Remote control has not been granted.")
        }

        var pressed: [MacRemoteKey] = []
        do {
            for key in keys {
                let result = try await client.sendMacRemoteKey(
                    controllerID: controllerID,
                    generation: generation,
                    key: key,
                    pressed: true
                )
                guard result.accepted else {
                    await emergencyStopAfterInputFailure(using: client)
                    return .failed("The Mac rejected remote input.")
                }
                pressed.append(key)
            }
            for key in pressed.reversed() {
                let result = try await client.sendMacRemoteKey(
                    controllerID: controllerID,
                    generation: generation,
                    key: key,
                    pressed: false
                )
                guard result.accepted else {
                    await emergencyStopAfterInputFailure(using: client)
                    return .failed("The Mac rejected remote input release.")
                }
            }
            return .performed
        } catch {
            await emergencyStopAfterInputFailure(using: client)
            didFail(error)
            return .failed(error.localizedDescription)
        }
    }

    private func emergencyStopAfterInputFailure(using client: FarRelayHostClient) async {
        try? await client.emergencyStopMacRemote()
        generation = nil
        keyboardForwardingActive = false
        if case .failed = state {
            return
        }
        state = .connected
    }

    private func didConnect(client: FarRelayHostClient, subscription: Bool) {
        self.client = client
        speechSubscriptionActive = subscription
        state = .connected
    }

    private func consume(events: AsyncStream<MacRemoteHostEvent>) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: MacRemoteHostEvent) {
        guard let speechEvent = event.speech else { return }
        if speechGeneration != speechEvent.generation {
            speechGeneration = speechEvent.generation
            lastSpeechSequence = 0
            Task { await speech.cancel() }
        }
        guard speechEvent.sequence > lastSpeechSequence else { return }
        lastSpeechSequence = speechEvent.sequence
        if speechEvent.kind == "cancel" || event.name == "speech.cancel" {
            Task { await speech.cancel() }
        } else if event.name == "speech.utterance" {
            Task { await speech.speak(ssml: speechEvent.ssml, fallback: speechEvent.plainText) }
        }
    }

    private func didFail(_ error: Error) {
        state = .failed(error.localizedDescription)
        keyboardForwardingActive = false
    }

    private func didEnd() {
        guard !Task.isCancelled else { return }
        if case .failed = state { return }
        state = .disconnected
        keyboardForwardingActive = false
        speechSubscriptionActive = false
        eventTask?.cancel()
        eventTask = nil
        client = nil
        session = nil
        task = nil
        activeProfile = nil
    }
}

extension MacRemoteSession: MacRemoteIntentControlling {}
