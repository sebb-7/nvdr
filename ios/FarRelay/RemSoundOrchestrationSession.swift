import Foundation
import Observation

struct RemSoundHostHandshake: Equatable, Sendable {
    let capabilities: HostCapabilities
    let descriptor: HostRemSoundSessionDescriptor
}

enum RemSoundOrchestrationError: LocalizedError, Equatable, Sendable {
    case unsupportedProfile
    case hostCapabilityUnavailable
    case missingPassword
    case unsupportedSession(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProfile:
            return "Remote audio orchestration requires a configured Windows computer."
        case .hostCapabilityUnavailable:
            return "This FarRelay Host does not advertise remote audio orchestration."
        case .missingPassword:
            return "A RemSound shared password is required for this computer."
        case .unsupportedSession(let detail):
            return "The RemSound session is not compatible with this receiver: \(detail)"
        }
    }
}

enum RemSoundOrchestrationContract {
    nonisolated static func validate(capabilities: HostCapabilities) throws {
        guard capabilities.operations.contains("remsound.session"),
              capabilities.features?.contains("remoteAudioOrchestration") == true
        else {
            throw RemSoundOrchestrationError.hostCapabilityUnavailable
        }
    }

    nonisolated static func validate(descriptor: HostRemSoundSessionDescriptor) throws {
        guard descriptor.transport == "direct_udp" else {
            throw RemSoundOrchestrationError.unsupportedSession("expected direct UDP transport")
        }
        guard descriptor.audioPort > 0 else {
            throw RemSoundOrchestrationError.unsupportedSession("audio port is invalid")
        }
        guard descriptor.discoveryPort == 47_821 else {
            throw RemSoundOrchestrationError.unsupportedSession("unsupported discovery port")
        }
        guard descriptor.sampleRateHz == 48_000, descriptor.channels == 2 else {
            throw RemSoundOrchestrationError.unsupportedSession("expected 48 kHz stereo audio")
        }
        let codecs = Set(descriptor.codecs.map { $0.lowercased() })
        guard codecs.contains("opus") || codecs.contains("pcm") else {
            throw RemSoundOrchestrationError.unsupportedSession("no supported codec was advertised")
        }
        guard descriptor.sharedPasswordRequired else {
            throw RemSoundOrchestrationError.unsupportedSession("this receiver requires the shared-password contract")
        }
        guard descriptor.senderState == .running || descriptor.senderState == .starting else {
            throw RemSoundOrchestrationError.unsupportedSession("sender did not enter a runnable state")
        }
    }
}

@MainActor
protocol RemSoundHostOrchestrating: AnyObject {
    func handshake(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> RemSoundHostHandshake
    func status(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundStatus
    func startSender(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundActionResult
    func stopSender(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundActionResult
    func restartSender(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundActionResult
}

@MainActor
final class SSHRemSoundHostOrchestrator: RemSoundHostOrchestrating {
    func handshake(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> RemSoundHostHandshake {
        try await withClient(profile: profile, credentials: credentials) { client in
            let capabilities = try await client.capabilities()
            try RemSoundOrchestrationContract.validate(capabilities: capabilities)
            let descriptor = try await client.remSoundSession()
            return RemSoundHostHandshake(capabilities: capabilities, descriptor: descriptor)
        }
    }

    func status(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundStatus {
        try await withClient(profile: profile, credentials: credentials) { client in
            try await client.remSoundStatus()
        }
    }

    func startSender(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundActionResult {
        try await withClient(profile: profile, credentials: credentials) { client in
            try await client.startRemSound()
        }
    }

    func stopSender(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundActionResult {
        try await withClient(profile: profile, credentials: credentials) { client in
            try await client.stopRemSound()
        }
    }

    func restartSender(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundActionResult {
        try await withClient(profile: profile, credentials: credentials) { client in
            try await client.restartRemSound()
        }
    }

    private func withClient<Result: Sendable>(
        profile: HostProfile,
        credentials: HostProfileCredentials,
        operation: @escaping @Sendable (FarRelayHostClient) async throws -> Result
    ) async throws -> Result {
        let command = try HostRecoverySession.hostCommand(for: profile)
        let session = SSHSession(configuration: profile.sshSessionConfiguration(credentials: credentials))
        do {
            try await session.connect()
            let result = try await FarRelayHostConnection.withClient(
                session: session,
                command: command,
                operation: operation
            )
            try await session.close()
            return result
        } catch {
            try? await session.close()
            throw error
        }
    }
}

@MainActor
protocol RemSoundReceiverControlling: AnyObject {
    var snapshot: AudioReceiverSnapshot { get }
    func start(
        host: String,
        port: UInt16,
        password: String,
        targetLatencyMilliseconds: Int,
        autoTuneLatencyEnabled: Bool
    )
    func stop()
    func reconnect()
}

extension AudioReceiverModel: RemSoundReceiverControlling {}

@Observable
@MainActor
final class RemSoundOrchestrationSession {
    enum State: Equatable {
        case unavailable(String)
        case idle
        case requestingSession
        case startingSender
        case connectingReceiver
        case buffering
        case playing
        case reconnecting
        case degraded(String)
        case failed(String)
        case stopped
    }

    private(set) var phase: State = .idle
    private(set) var activeProfileID: UUID?
    private(set) var descriptor: HostRemSoundSessionDescriptor?
    private(set) var senderStatus: HostRemSoundStatus?
    private(set) var senderState: HostRemSoundLifecycleState?

    @ObservationIgnored private let host: any RemSoundHostOrchestrating
    @ObservationIgnored private let receiver: any RemSoundReceiverControlling
    @ObservationIgnored private var generation = 0

    init(
        receiver: any RemSoundReceiverControlling,
        host: any RemSoundHostOrchestrating = SSHRemSoundHostOrchestrator()
    ) {
        self.receiver = receiver
        self.host = host
    }

    var state: State {
        switch phase {
        case .unavailable, .idle, .requestingSession, .degraded, .failed, .stopped:
            return phase
        case .startingSender, .connectingReceiver, .buffering, .playing, .reconnecting:
            break
        }

        switch receiver.snapshot.state {
        case .idle:
            return phase == .startingSender ? .startingSender : .connectingReceiver
        case .connecting, .authenticating, .waitingForAudio:
            return .connectingReceiver
        case .buffering:
            return .buffering
        case .playing:
            return .playing
        case .reconnecting:
            return .reconnecting
        case .stopped:
            return .stopped
        case .failed(let message):
            return .degraded(message)
        }
    }

    var statusLabel: String {
        switch state {
        case .unavailable(let message): "Unavailable: \(message)"
        case .idle: "Idle"
        case .requestingSession: "Requesting audio session"
        case .startingSender: "Starting Windows RemSound"
        case .connectingReceiver: "Connecting receiver"
        case .buffering: "Buffering"
        case .playing: "Playing"
        case .reconnecting: "Reconnecting audio"
        case .degraded(let message): "Audio degraded: \(message)"
        case .failed(let message): "Failed: \(message)"
        case .stopped: "Stopped"
        }
    }

    func start(
        profile: HostProfile,
        credentials: HostProfileCredentials,
        targetLatencyMilliseconds: Int = 80,
        autoTuneLatencyEnabled: Bool = false
    ) async {
        generation &+= 1
        let requestGeneration = generation

        guard profile.platform == .windows, profile.isConnectionReady else {
            activeProfileID = profile.id
            phase = .unavailable(RemSoundOrchestrationError.unsupportedProfile.localizedDescription)
            return
        }

        activeProfileID = profile.id
        descriptor = nil
        senderStatus = nil
        senderState = nil
        phase = .requestingSession

        do {
            let handshake = try await host.handshake(profile: profile, credentials: credentials)
            guard requestGeneration == generation else { return }

            try RemSoundOrchestrationContract.validate(capabilities: handshake.capabilities)
            try RemSoundOrchestrationContract.validate(descriptor: handshake.descriptor)
            if handshake.descriptor.sharedPasswordRequired && credentials.remSoundPassword.isEmpty {
                throw RemSoundOrchestrationError.missingPassword
            }

            descriptor = handshake.descriptor
            senderState = handshake.descriptor.senderState
            phase = handshake.descriptor.senderState == .starting ? .startingSender : .connectingReceiver

            receiver.start(
                host: profile.address.trimmingCharacters(in: .whitespacesAndNewlines),
                port: handshake.descriptor.audioPort,
                password: credentials.remSoundPassword,
                targetLatencyMilliseconds: targetLatencyMilliseconds,
                autoTuneLatencyEnabled: autoTuneLatencyEnabled
            )
        } catch {
            guard requestGeneration == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func stopAudio() {
        generation &+= 1
        receiver.stop()
        phase = .stopped
    }

    func reconnectAudio() {
        guard activeProfileID != nil else { return }
        receiver.reconnect()
        phase = .reconnecting
    }

    func restartAudio(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async {
        generation &+= 1
        let requestGeneration = generation
        guard activeProfileID == profile.id else {
            phase = .failed("Start remote audio before restarting it.")
            return
        }

        phase = .reconnecting
        do {
            let result = try await host.restartSender(profile: profile, credentials: credentials)
            guard requestGeneration == generation else { return }
            senderState = result.state
            receiver.reconnect()
        } catch {
            guard requestGeneration == generation else { return }
            if case .playing = receiver.snapshot.state {
                phase = .degraded("Audio restart failed while playback continues: \(error.localizedDescription)")
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func refreshSenderStatus(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async {
        do {
            let status = try await host.status(profile: profile, credentials: credentials)
            senderStatus = status
            senderState = status.state
            if case .degraded = phase {
                phase = switch receiver.snapshot.state {
                case .idle: .idle
                case .connecting, .authenticating, .waitingForAudio: .connectingReceiver
                case .buffering: .buffering
                case .playing: .playing
                case .reconnecting: .reconnecting
                case .stopped: .stopped
                case .failed(let message): .degraded(message)
                }
            }
        } catch {
            if case .playing = receiver.snapshot.state {
                phase = .degraded("Sender status unavailable while audio continues: \(error.localizedDescription)")
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    @discardableResult
    func startSender(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundActionResult {
        let result = try await host.startSender(profile: profile, credentials: credentials)
        senderState = result.state
        return result
    }

    @discardableResult
    func stopSender(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundActionResult {
        let result = try await host.stopSender(profile: profile, credentials: credentials)
        senderState = result.state
        return result
    }

    @discardableResult
    func restartSender(
        profile: HostProfile,
        credentials: HostProfileCredentials
    ) async throws -> HostRemSoundActionResult {
        let result = try await host.restartSender(profile: profile, credentials: credentials)
        senderState = result.state
        return result
    }
}
