import AVFoundation
import Observation

@MainActor
@Observable
final class AudioReceiverModel {
    private let receiver: RemSoundAudioReceiver
    private let playback: AudioPlayback
    private let discovery = RemSoundDiscoveryAnnouncer()
    private var updatesTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private(set) var snapshot = AudioReceiverSnapshot()
    private(set) var discoveryDiagnostics = RemSoundDiscoveryDiagnostics()

    init(receiver: RemSoundAudioReceiver = RemSoundAudioReceiver()) {
        self.receiver = receiver
        playback = AudioPlayback { [receiver] message in
            Task { await receiver.playbackFailed(message) }
        } onDroppedFrame: { [receiver] frameCount in
            Task { await receiver.playbackDropped(frameCount: frameCount) }
        }
        discovery.onDiagnosticsChanged = { [weak self] diagnostics in
            self?.discoveryDiagnostics = diagnostics
        }
        discoveryDiagnostics = discovery.diagnostics
        updatesTask = Task { [weak self, receiver] in
            let updates = await receiver.updates()
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                self?.snapshot = snapshot
                self?.playback.setMuted(snapshot.muted)
                self?.playback.setVolume(snapshot.volume)
                switch snapshot.state {
                case .reconnecting:
                    self?.playback.stop()
                    self?.playback.resetFailureLatch()
                case .stopped, .failed:
                    self?.playback.stop()
                case .connecting, .authenticating:
                    self?.playback.resetFailureLatch()
                case .idle, .waitingForAudio, .buffering, .playing:
                    break
                }
            }
        }
        playbackTask = Task { [weak self, receiver] in
            let frames = await receiver.pcmFrames()
            for await frame in frames {
                guard !Task.isCancelled else { return }
                self?.playback.enqueue(frame)
            }
        }
    }

    isolated deinit {
        updatesTask?.cancel()
        playbackTask?.cancel()
    }

    func start(host: String, port: UInt16 = 47_830, password: String) {
        discovery.start(peerHost: host, audioPort: port)
        Task { await receiver.start(configuration: .init(host: host, port: port, password: password)) }
    }

    func stop() {
        discovery.stop()
        Task { await receiver.stop() }
    }

    func reconnect() {
        discovery.reconnect()
        Task { await receiver.reconnect() }
    }

    func setMuted(_ muted: Bool) { Task { await receiver.setMuted(muted) } }
    func setVolume(_ volume: Float) { Task { await receiver.setVolume(volume) } }

    /// A concise state intended for the Remote tab. Heartbeats prove the
    /// Windows app can reach this device but do not imply password success.
    var compactStatusLabel: String {
        return switch snapshot.state {
        case .idle: "Idle"
        case .connecting: "Connecting"
        case .authenticating: "Authenticating"
        case .waitingForAudio: "Windows online — waiting for audio"
        case .buffering: "Buffering"
        case .playing: "Playing"
        case .reconnecting: "Reconnecting"
        case .stopped: "Stopped"
        case .failed(let message): "Failed: \(message)"
        }
    }

    /// Copy-safe diagnostics deliberately exclude the shared password, derived
    /// key/fingerprint, packet plaintext, and audio samples.
    func diagnosticReport(profile: HostProfile) -> String {
        let capability = profile.remSoundReceiver?.normalized()
            ?? RemSoundReceiverCapability(senderHost: profile.address)
        let statistics = snapshot.statistics
        let discovery = discoveryDiagnostics
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return [
            "FarRelay RemSound diagnostic report",
            "App version: \(version)",
            "Build: \(build)",
            "Computer: \(profile.displayName)",
            "Windows RemSound address: \(capability.senderHost)",
            "Audio UDP port: \(capability.senderPort)",
            "Discovery UDP port: \(RemSoundDiscovery.defaultPort)",
            "State: \(compactStatusLabel)",
            "Receiver listening: \(snapshot.isListening)",
            "Receiver peer: \(snapshot.peer ?? "none")",
            "Discovery active: \(discovery.isActive)",
            "Discovery target: \(discovery.target ?? "none")",
            "Discovery announcements attempted: \(discovery.announcementsAttempted)",
            "Discovery sends completed locally: \(discovery.announcementsCompleted)",
            "Discovery send failures: \(discovery.announcementFailures)",
            "Discovery announcements received: \(discovery.announcementsReceived)",
            "Discovery malformed announcements: \(discovery.malformedAnnouncements)",
            "Last discovered peer: \(discovery.lastDiscoveredPeer ?? "none")",
            "Selected RemSound peer: \(snapshot.peer ?? "none")",
            "Advertised CanReceive: true",
            "Advertised CanSend: false",
            "Heartbeat pings received: \(statistics.heartbeatPingsReceived)",
            "Heartbeat pongs sent: \(statistics.heartbeatPongsSent)",
            "Heartbeat pings sent: \(statistics.heartbeatPingsSent)",
            "Heartbeat pongs received: \(statistics.heartbeatPongsReceived)",
            "Heartbeat round-trip milliseconds: \(statistics.heartbeatRoundTripMilliseconds.map(String.init) ?? "pending")",
            "Heartbeat reply failures: \(statistics.heartbeatReplyFailures)",
            "Format packets received: \(statistics.formatPacketsReceived)",
            "Compatible Format packets accepted: \(statistics.compatibleFormatPacketsAccepted)",
            "Unsupported Format packets: \(statistics.unsupportedFormatPackets)",
            "Audio UDP packets received: \(statistics.packetsReceived)",
            "Encrypted audio packets received: \(statistics.encryptedAudioPacketsReceived)",
            "Packets dropped: \(statistics.packetsDropped)",
            "Packets lost: \(statistics.packetsLost)",
            "Packets reordered: \(statistics.packetsReordered)",
            "Authentication successes: \(statistics.authenticationSuccesses)",
            "Authentication failures: \(statistics.authenticationFailures)",
            "Format authentication failures: \(statistics.formatAuthenticationFailures)",
            "Encrypted audio authentication failures: \(statistics.encryptedAudioAuthenticationFailures)",
            "Malformed packets: \(statistics.malformedPackets)",
            "Unsupported packets: \(statistics.unsupportedPackets)",
            "AddrCheck received: \(statistics.addrChecksReceived)",
            "AddrCheck replies sent: \(statistics.addrCheckRepliesSent)",
            "Control received: \(statistics.controlPacketsReceived)",
            "KeepAlive received: \(statistics.keepAlivePacketsReceived)",
            "Buffer depth frames: \(statistics.bufferDepthFrames)",
            "Last audio error: \(statistics.lastError ?? "none")",
            "Last discovery error: \(discovery.lastError ?? "none")",
            "Sensitive data: passwords, keys, fingerprints, packet plaintext, and audio content are not recorded."
        ].joined(separator: "\n")
    }
}

@MainActor
private final class AudioPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat?
    private static let maximumScheduledBuffers = 16
    private var muted = false
    private var volume: Float = 1
    private var scheduledBufferCount = 0
    private var notificationTokens: [NSObjectProtocol] = []
    private var sessionConfigured = false
    private var failureLatched = false
    private let onFailure: (String) -> Void
    private let onDroppedFrame: (Int) -> Void

    init(onFailure: @escaping (String) -> Void, onDroppedFrame: @escaping (Int) -> Void) {
        self.onFailure = onFailure
        self.onDroppedFrame = onDroppedFrame
        format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        guard let format else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        observeAudioSession()
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        player.volume = muted ? 0 : volume
    }

    func setVolume(_ volume: Float) {
        self.volume = volume
        player.volume = muted ? 0 : volume
    }

    func resetFailureLatch() {
        failureLatched = false
    }

    func enqueue(_ frame: AudioPCMFrame) {
        guard let format, frame.sampleRate == format.sampleRate, frame.channels == 2 else { return }
        let frameCount = frame.samples.count / frame.channels
        guard frameCount > 0 else { return }
        guard !failureLatched else {
            onDroppedFrame(frameCount)
            return
        }
        guard scheduledBufferCount < Self.maximumScheduledBuffers else {
            onDroppedFrame(frameCount)
            return
        }
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
            let channels = buffer.floatChannelData
        else { return }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        for index in 0..<frameCount {
            channels[0][index] = frame.samples[index * 2]
            channels[1][index] = frame.samples[index * 2 + 1]
        }

        do {
            try ensureOutputStarted()
            scheduledBufferCount += 1
            player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduledBufferCount = max((self?.scheduledBufferCount ?? 1) - 1, 0)
                }
            }
        } catch {
            failureLatched = true
            onFailure("Audio playback failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        scheduledBufferCount = 0
        if sessionConfigured {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionConfigured = false
        }
    }

    private func ensureOutputStarted() throws {
        let session = AVAudioSession.sharedInstance()

        if !sessionConfigured {
            // Playback already supports A2DP and AirPlay routes. Keep FarRelay
            // mixable so VoiceOver and the app's own feedback remain audible.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setPreferredSampleRate(48_000)
            sessionConfigured = true
        }

        if !engine.isRunning {
            try session.setActive(true)
            engine.prepare()
            try engine.start()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    private func restartOutputIfNeeded() {
        guard !failureLatched, sessionConfigured, !engine.isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            engine.prepare()
            try engine.start()
            if !player.isPlaying {
                player.play()
            }
        } catch {
            failureLatched = true
            onFailure("Audio playback restart failed: \(error.localizedDescription)")
        }
    }

    private func observeAudioSession() {
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.ended.rawValue
            else { return }
            Task { @MainActor in
                self?.restartOutputIfNeeded()
            }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restartOutputIfNeeded()
            }
        })
    }

    isolated deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
