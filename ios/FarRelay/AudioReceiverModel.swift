import AVFoundation
import Observation

@MainActor
@Observable
final class AudioReceiverModel {
    private let receiver: RemSoundAudioReceiver
    private var playback: AudioPlayback?
    private let discovery = RemSoundDiscoveryAnnouncer()
    private var updatesTask: Task<Void, Never>?
    private(set) var snapshot = AudioReceiverSnapshot()
    private(set) var discoveryDiagnostics = RemSoundDiscoveryDiagnostics()

    init(receiver: RemSoundAudioReceiver = RemSoundAudioReceiver()) {
        self.receiver = receiver
        discovery.onDiagnosticsChanged = { [weak self] diagnostics in
            self?.discoveryDiagnostics = diagnostics
        }
        discoveryDiagnostics = discovery.diagnostics
        updatesTask = Task { [weak self, receiver] in
            let updates = await receiver.updates()
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.snapshot = snapshot
                self.playback?.setMuted(snapshot.muted)
                self.playback?.setVolume(snapshot.volume)
                switch snapshot.state {
                case .reconnecting:
                    self.playback?.stop()
                    self.playback?.resetFailureLatch()
                case .stopped, .failed:
                    self.playback?.stop()
                case .connecting, .authenticating:
                    self.playback?.resetFailureLatch()
                case .buffering, .playing:
                    let playback = self.ensurePlayback()
                    playback.setMuted(snapshot.muted)
                    playback.setVolume(snapshot.volume)
                    playback.startIfNeeded()
                case .idle, .waitingForAudio:
                    break
                }
            }
        }
    }

    isolated deinit {
        updatesTask?.cancel()
    }

    private func ensurePlayback() -> AudioPlayback {
        if let playback { return playback }
        let playback = AudioPlayback(playout: receiver.playout) { [receiver] message in
            Task { await receiver.playbackFailed(message) }
        }
        self.playback = playback
        return playback
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
            "Codec: \(snapshot.codec.map { $0 == .opus ? "Opus" : "PCM" } ?? "unknown")",
            "Opus mode: \(snapshot.opusMode?.rawValue ?? "unknown")",
            "Sample rate: \(snapshot.sampleRate.map(String.init) ?? "unknown")",
            "Channels: \(snapshot.channelCount.map(String.init) ?? "unknown")",
            "Frame duration milliseconds: \(snapshot.frameDurationMilliseconds.map { $0.formatted(.number.precision(.fractionLength(1...2))) } ?? "unknown")",
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
            "Playback buffer dropped frames: \(statistics.bufferDroppedFrames)",
            "Packets lost: \(statistics.packetsLost)",
            "Packets reordered: \(statistics.packetsReordered)",
            "Packets duplicated: \(statistics.packetsDuplicated)",
            "Opus packets decoded: \(statistics.opusPacketsDecoded)",
            "Opus decode failures: \(statistics.opusDecodeFailures)",
            "Opus FEC recoveries: \(statistics.opusFECRecoveries)",
            "Opus PLC frames: \(statistics.opusPLCFrames)",
            "Playout initial target milliseconds: \(snapshot.sampleRate.map { Double(statistics.initialJitterTargetFrames) * 1_000 / Double($0) }.map { $0.formatted(.number.precision(.fractionLength(1...2))) } ?? "unknown")",
            "Playout target milliseconds: \(snapshot.sampleRate.map { Double(statistics.jitterTargetFrames) * 1_000 / Double($0) }.map { $0.formatted(.number.precision(.fractionLength(1...2))) } ?? "unknown")",
            "Playout buffered milliseconds: \(snapshot.sampleRate.map { Double(statistics.bufferDepthFrames) * 1_000 / Double($0) }.map { $0.formatted(.number.precision(.fractionLength(1...2))) } ?? "unknown")",
            "Jitter underruns: \(statistics.underruns)",
            "Producer-starvation underruns: \(statistics.producerStarvationUnderruns)",
            "Device/render-gulp underruns: \(statistics.deviceRenderGulpUnderruns)",
            "Concealed audio milliseconds: \(snapshot.sampleRate.map { Double(statistics.concealedAudioFrames) * 1_000 / Double($0) }.map { $0.formatted(.number.precision(.fractionLength(1...2))) } ?? "unknown")",
            "Playout trim events: \(statistics.trimEvents)",
            "Recent packet arrival gap milliseconds: \(statistics.recentPacketArrivalGapMilliseconds)",
            "Peak packet arrival gap milliseconds: \(statistics.peakPacketArrivalGapMilliseconds)",
            "Recent render callback gap milliseconds: \(statistics.recentRenderCallbackGapMilliseconds)",
            "Peak render callback gap milliseconds: \(statistics.peakRenderCallbackGapMilliseconds)",
            "Continuous auto-tune enabled: \(statistics.autoTuneEnabled)",
            "Last auto-tune decision: \(statistics.lastAutoTuneDecision)",
            "Late packets discarded: \(statistics.latePacketsDiscarded)",
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

/// AVAudioSourceNode invokes its render block on a CoreAudio real-time thread.
/// Build that block outside any actor-isolated context so Swift 6 does not
/// inherit MainActor isolation from AudioPlayback.init and trap when CoreAudio
/// invokes it off the main queue on physical devices.
private enum RemSoundSourceNodeFactory {
    nonisolated static func make(
        playout: RemSoundPlayoutBuffer,
        format: AVAudioFormat
    ) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            playout.render(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
    }
}

@MainActor
private final class AudioPlayback {
    private let engine = AVAudioEngine()
    private let source: AVAudioSourceNode
    private let format: AVAudioFormat?
    private var muted = false
    private var volume: Float = 1
    private var notificationTokens: [NSObjectProtocol] = []
    private var sessionConfigured = false
    private var failureLatched = false
    private let onFailure: (String) -> Void

    init(playout: RemSoundPlayoutBuffer, onFailure: @escaping (String) -> Void) {
        self.onFailure = onFailure
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            fatalError("Unable to create the fixed RemSound output format.")
        }
        self.format = format
        source = RemSoundSourceNodeFactory.make(playout: playout, format: format)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        observeAudioSession()
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        source.volume = muted ? 0 : volume
    }

    func setVolume(_ volume: Float) {
        self.volume = volume
        source.volume = muted ? 0 : volume
    }

    func resetFailureLatch() {
        failureLatched = false
    }

    func startIfNeeded() {
        guard !failureLatched else { return }
        do {
            try ensureOutputStarted()
        } catch {
            failureLatched = true
            onFailure("Audio playback failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.stop()
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
    }

    private func restartOutputIfNeeded() {
        guard !failureLatched, sessionConfigured, !engine.isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            engine.prepare()
            try engine.start()
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
