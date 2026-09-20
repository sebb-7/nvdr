import Foundation

/// Wire format spoken by `farrelay --ipc`. The Rust side is `src/ipc.rs`. Plain
/// ASCII, line-oriented, one event per line.
///
/// We send: `key <vk> <0|1>`, `combo <spec>`, `type <text>`, `release_all`,
/// `quit`. We receive: `speak <text>`, `cancel`, `state <name>`,
/// `error <message>`, `tone <hz> <milliseconds> <left> <right>`, and
/// `wave <basename.wav>`. Anything else on stdout is logged and dropped.
enum IPCEvent: Sendable, Equatable {
    case speak(String)
    case cancel
    case state(BridgeState)
    case error(String)
    case tone(RemoteNVDATone)
    case wave(String)
    case unknown(String)
}

enum BridgeState: String, Sendable {
    case connecting
    case relayConnected = "relay_connected"
    case waitingForNVDA = "waiting_for_nvda"
    case ready
    case nvdaNotConnected = "nvda_not_connected"
    case disconnected
    case quit
    case unknown
}

enum IPCCommand: Sendable {
    case key(vk: UInt16, pressed: Bool)
    case combo(String)
    case type(String)
    case sas
    case releaseAll
    case quit

    var line: String {
        switch self {
        case let .key(vk, pressed):
            return "key \(vk) \(pressed ? 1 : 0)"
        case let .combo(spec):
            return "combo \(spec)"
        case let .type(text):
            return "type \(escape(text))"
        case .sas:
            return "sas"
        case .releaseAll:
            return "release_all"
        case .quit:
            return "quit"
        }
    }

    /// Mirror of the `unescape` in `src/ipc.rs` (`\n`, `\r`, `\t`, `\\`).
    private func escape(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }
}

enum IPCParser {
    static func parse(_ raw: String) -> IPCEvent {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        if line.isEmpty { return .unknown("") }
        let split = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(split[0])
        let rest = split.count > 1 ? String(split[1]) : ""
        switch head {
        case "speak":
            return .speak(rest)
        case "cancel":
            return .cancel
        case "state":
            return .state(BridgeState(rawValue: rest) ?? .unknown)
        case "error":
            return .error(rest)
        case "tone":
            let values = rest.split(separator: " ", omittingEmptySubsequences: true).compactMap { Int($0) }
            guard values.count == 4, let tone = RemoteNVDATone(frequency: values[0], durationMilliseconds: values[1], leftLevel: values[2], rightLevel: values[3]) else { return .unknown(line) }
            return .tone(tone)
        case "wave":
            guard let filename = SoundResourceResolver.remoteWaveFilename(from: rest) else { return .unknown(line) }
            return .wave(filename)
        default:
            return .unknown(line)
        }
    }
}
