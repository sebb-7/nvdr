import Foundation

/// FarRelay-owned boundary for live audio input. Implementations must never
/// require a control-plane connection to start, stop, or report their state.
protocol AudioReceiver: Sendable {
    func start(configuration: AudioReceiverConfiguration) async
    func stop() async
    func reconnect() async
    func setMuted(_ muted: Bool) async
    func setVolume(_ volume: Float) async
    func snapshot() async -> AudioReceiverSnapshot
    func updates() async -> AsyncStream<AudioReceiverSnapshot>
}

struct AudioReceiverConfiguration: Equatable, Sendable {
    let host: String
    let port: UInt16
    let password: String
    let targetLatencyMilliseconds: Int
    let autoTuneLatencyEnabled: Bool

    init(
        host: String,
        port: UInt16 = 47_830,
        password: String,
        targetLatencyMilliseconds: Int = 80,
        autoTuneLatencyEnabled: Bool = false
    ) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.password = password
        self.targetLatencyMilliseconds = min(max(targetLatencyMilliseconds, 20), 500)
        self.autoTuneLatencyEnabled = autoTuneLatencyEnabled
    }
}

enum AudioReceiverState: Equatable, Sendable {
    case idle
    case connecting
    case authenticating
    case waitingForAudio
    case buffering
    case playing
    case reconnecting
    case stopped
    case failed(String)

    var accessibilityLabel: String {
        switch self {
        case .idle: "Audio idle"
        case .connecting: "Audio connecting"
        case .authenticating: "Audio authenticating"
        case .waitingForAudio: "Windows online, waiting for audio"
        case .buffering: "Audio buffering"
        case .playing: "Audio playing"
        case .reconnecting: "Audio reconnecting"
        case .stopped: "Audio stopped"
        case .failed(let message): "Audio failed: \(message)"
        }
    }
}

struct AudioReceiverStatistics: Equatable, Sendable {
    var packetsReceived = 0
    var packetsDropped = 0
    var packetsLost = 0
    var packetsReordered = 0
    var packetsDuplicated = 0
    var duplicatePathsSuppressed = 0
    var pathHandovers = 0
    var authenticationFailures = 0
    var authenticationSuccesses = 0
    var formatAuthenticationFailures = 0
    var encryptedAudioPacketsReceived = 0
    var formatPacketsReceived = 0
    var compatibleFormatPacketsAccepted = 0
    var unsupportedFormatPackets = 0
    var encryptedAudioAuthenticationFailures = 0
    var heartbeatPingsReceived = 0
    var heartbeatPongsSent = 0
    var heartbeatPingsSent = 0
    var heartbeatPongsReceived = 0
    var heartbeatReplyFailures = 0
    var heartbeatRoundTripMilliseconds: Int?
    var addrChecksReceived = 0
    var addrCheckRepliesSent = 0
    var controlPacketsReceived = 0
    var keepAlivePacketsReceived = 0
    var malformedPackets = 0
    var unsupportedPackets = 0
    var bufferDepthFrames = 0
    var bufferDroppedFrames = 0
    var underruns = 0
    var latePacketsDiscarded = 0
    var opusPacketsDecoded = 0
    var opusDecodeFailures = 0
    var opusFECRecoveries = 0
    var opusPLCFrames = 0
    var jitterTargetFrames = 0
    var initialJitterTargetFrames = 0
    var concealedAudioFrames = 0
    var trimEvents = 0
    var producerStarvationUnderruns = 0
    var deviceRenderGulpUnderruns = 0
    var recentPacketArrivalGapMilliseconds = 0
    var peakPacketArrivalGapMilliseconds = 0
    var recentRenderCallbackGapMilliseconds = 0
    var peakRenderCallbackGapMilliseconds = 0
    var autoTuneEnabled = true
    var lastAutoTuneDecision = "waiting for measurements"
    var reconnects = 0
    var lastError: String?
}

struct AudioReceiverSnapshot: Equatable, Sendable {
    var state: AudioReceiverState = .idle
    var muted = false
    var volume: Float = 1
    var peer: String?
    var isListening = false
    var sampleRate: Int?
    var channelCount: Int?
    var codec: RemSoundCodec?
    var opusMode: RemSoundOpusMode?
    var frameDurationMilliseconds: Double?
    var statistics = AudioReceiverStatistics()
}

struct AudioPCMFrame: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let channels: Int
}
