import Foundation

/// App-owned meanings map to filenames in one place. Native NVDA sounds are
/// separate because they come from the remote protocol, not app inference.
enum InteractionSoundIntent: Equatable, Hashable, Sendable {
    case remoteConnected, disconnected, keyboardRemote, keyboardLocal, terminalOpen
    case pushClipboard, receiveClipboard, nvdaStarted, nvdaStopped
    case action, success, warning, error, copied

    var filename: String {
        switch self {
        case .remoteConnected: "connected.wav"; case .disconnected: "disconnected.wav"
        case .keyboardRemote: "keyboard-remote.wav"; case .keyboardLocal: "keyboard-local.wav"
        case .terminalOpen: "terminal-open.wav"; case .pushClipboard: "push_clipboard.wav"
        case .receiveClipboard: "receive_clipboard.wav"; case .nvdaStarted: "nvda-started.wav"
        case .nvdaStopped: "nvda-stopped.wav"; case .action: "action.wav"
        case .success: "success.wav"; case .warning: "warning.wav"
        case .error: "error.wav"; case .copied: "copied.wav"
        }
    }
}

struct RemoteNVDATone: Equatable, Hashable, Sendable {
    let frequency: Int; let durationMilliseconds: Int; let leftLevel: Int; let rightLevel: Int
    init?(frequency: Int, durationMilliseconds: Int, leftLevel: Int, rightLevel: Int) {
        guard (20...20_000).contains(frequency), (1...5_000).contains(durationMilliseconds), (0...100).contains(leftLevel), (0...100).contains(rightLevel) else { return nil }
        self.frequency = frequency; self.durationMilliseconds = durationMilliseconds
        self.leftLevel = leftLevel; self.rightLevel = rightLevel
    }
}

enum SoundResourceResolver {
    static func remoteWaveFilename(from remote: String) -> String? {
        guard !remote.contains("..") else { return nil }
        let filename = remote.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
        guard let filename, !filename.isEmpty, filename.lowercased().hasSuffix(".wav") else { return nil }
        return filename
    }

    static func bundledURL(for filename: String, in bundle: Bundle = .main) -> URL? {
        guard let safe = remoteWaveFilename(from: filename) else { return nil }
        let stem = String(safe.dropLast(4))

        // XcodeGen preserves ../sounds as a folder resource, so TestFlight
        // builds may place WAVs under Bundle.main/sounds instead of at the
        // bundle root. Search both layouts because local/generated projects
        // have used both over the lifetime of FarRelay.
        let subdirectories: [String?] = [nil, "sounds"]
        for subdirectory in subdirectories {
            if let direct = bundle.url(
                forResource: stem,
                withExtension: "wav",
                subdirectory: subdirectory
            ) {
                return direct
            }
            if let match = bundle.urls(
                forResourcesWithExtension: "wav",
                subdirectory: subdirectory
            )?.first(where: {
                $0.lastPathComponent.caseInsensitiveCompare(safe) == .orderedSame
            }) {
                return match
            }
        }
        return nil
    }
}
