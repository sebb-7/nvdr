import Foundation

/// App-owned meanings map to default filenames in one place. Native NVDA
/// sounds are separate because they come from the remote protocol, not app
/// inference. Raw values are persisted as stable preference keys.
enum InteractionSoundIntent: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case remoteConnected
    case disconnected
    case keyboardRemote
    case keyboardLocal
    case terminalOpen
    case pushClipboard
    case receiveClipboard
    case nvdaStarted
    case nvdaStopped
    case action
    case success
    case warning
    case error
    case copied
    case layerExit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .remoteConnected: "Remote connected"
        case .disconnected: "Remote disconnected"
        case .keyboardRemote: "Keyboard forwarding on"
        case .keyboardLocal: "Keyboard forwarding off"
        case .terminalOpen: "Terminal opened"
        case .pushClipboard: "Clipboard sent"
        case .receiveClipboard: "Clipboard received"
        case .nvdaStarted: "NVDA started"
        case .nvdaStopped: "NVDA stopped"
        case .action: "Action accepted"
        case .success: "Success"
        case .warning: "Warning"
        case .error: "Error"
        case .copied: "Copied"
        case .layerExit: "Action layer completed"
        }
    }

    var defaultFilename: String {
        switch self {
        case .remoteConnected: "connected.wav"
        case .disconnected: "disconnected.wav"
        case .keyboardRemote: "keyboard-remote.wav"
        case .keyboardLocal: "keyboard-local.wav"
        case .terminalOpen: "terminal-open.wav"
        case .pushClipboard: "push_clipboard.wav"
        case .receiveClipboard: "receive_clipboard.wav"
        case .nvdaStarted: "nvda-started.wav"
        case .nvdaStopped: "nvda-stopped.wav"
        case .action: "action.wav"
        case .success: "success.wav"
        case .warning: "warning.wav"
        case .error: "error.wav"
        case .copied: "copied.wav"
        // `exit.wav` is byte-for-byte the same asset as `nvda-stopped.wav` in
        // the current sound pack. A layer returning to Base is not an NVDA
        // shutdown, so default it to the ordinary action cue instead.
        case .layerExit: "action.wav"
        }
    }

    /// Backward-compatible spelling for callers that only need the default.
    var filename: String { defaultFilename }
}

struct InteractionSoundPreference: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var filename: String
}

struct InteractionSoundPreferences: Codable, Equatable, Sendable {
    private var overrides: [String: InteractionSoundPreference] = [:]

    func preference(for intent: InteractionSoundIntent) -> InteractionSoundPreference {
        let stored = overrides[intent.rawValue]
        let safeFilename = stored.flatMap { AppSoundCatalog.contains(filename: $0.filename) ? $0.filename : nil }
        return InteractionSoundPreference(
            isEnabled: stored?.isEnabled ?? true,
            filename: safeFilename ?? intent.defaultFilename
        )
    }

    mutating func setEnabled(_ enabled: Bool, for intent: InteractionSoundIntent) {
        var preference = preference(for: intent)
        preference.isEnabled = enabled
        overrides[intent.rawValue] = preference
    }

    mutating func setFilename(_ filename: String, for intent: InteractionSoundIntent) {
        guard AppSoundCatalog.contains(filename: filename) else { return }
        var preference = preference(for: intent)
        preference.filename = filename
        overrides[intent.rawValue] = preference
    }
}

struct AppSoundOption: Equatable, Hashable, Identifiable, Sendable {
    let filename: String
    let label: String
    var id: String { filename }
}

enum AppSoundCatalog {
    /// Existing WAV resources shipped by FarRelay. Alias files that contain
    /// identical audio remain listed when their names carry a useful meaning;
    /// preferences always store the filename, never file-system paths.
    static let all: [AppSoundOption] = [
        .init(filename: "action.wav", label: "Action"),
        .init(filename: "browseMode.wav", label: "Browse mode"),
        .init(filename: "clipboardPush.wav", label: "Clipboard push"),
        .init(filename: "clipboardReceive.wav", label: "Clipboard receive"),
        .init(filename: "connected.wav", label: "Connected"),
        .init(filename: "controlled.wav", label: "Controlled"),
        .init(filename: "controlling.wav", label: "Controlling"),
        .init(filename: "copied.wav", label: "Copied"),
        .init(filename: "disconnected.wav", label: "Disconnected"),
        .init(filename: "error.wav", label: "Error"),
        .init(filename: "exit.wav", label: "Exit"),
        .init(filename: "focusMode.wav", label: "Focus mode"),
        .init(filename: "keyboard-local.wav", label: "Keyboard local"),
        .init(filename: "keyboard-remote.wav", label: "Keyboard remote"),
        .init(filename: "nvda-started.wav", label: "NVDA started"),
        .init(filename: "nvda-stopped.wav", label: "NVDA stopped"),
        .init(filename: "push_clipboard.wav", label: "Push clipboard"),
        .init(filename: "receive_clipboard.wav", label: "Receive clipboard"),
        .init(filename: "screenCurtainOff.wav", label: "Screen curtain off"),
        .init(filename: "screenCurtainOn.wav", label: "Screen curtain on"),
        .init(filename: "start.wav", label: "Start"),
        .init(filename: "success.wav", label: "Success"),
        .init(filename: "suggestionsClosed.wav", label: "Suggestions closed"),
        .init(filename: "suggestionsOpened.wav", label: "Suggestions opened"),
        .init(filename: "terminal-open.wav", label: "Terminal opened"),
        .init(filename: "textError.wav", label: "Text error"),
        .init(filename: "warning.wav", label: "Warning")
    ]

    static func contains(filename: String) -> Bool {
        all.contains { $0.filename == filename }
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
