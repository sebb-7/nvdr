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

    init(host: String, port: UInt16 = 47_830, password: String) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.password = password
    }
}

enum AudioReceiverState: Equatable, Sendable {
    case idle
    case connecting
    case authenticating
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
    var authenticationFailures = 0
    var bufferDepthFrames = 0
    var bufferDroppedFrames = 0
    var underruns = 0
    var reconnects = 0
    var lastError: String?
}

struct AudioReceiverSnapshot: Equatable, Sendable {
    var state: AudioReceiverState = .idle
    var muted = false
    var volume: Float = 1
    var peer: String?
    var sampleRate: Int?
    var channelCount: Int?
    var statistics = AudioReceiverStatistics()
}

struct AudioPCMFrame: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let channels: Int
}
