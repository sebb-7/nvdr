import Foundation
import Observation

/// A bounded, opt-in trace of remote keyboard handling. It intentionally
/// contains no key characters, credentials, terminal output, or speech.
enum InputDiagnosticSource: String, Sendable {
    case rawPress = "raw press"
    case keyCommand = "key command"
    case responder = "responder"
}

struct InputDiagnosticEntry: Identifiable, Sendable {
    let id = UUID()
    let sequence: Int
    let source: InputDiagnosticSource
    let hidUsage: Int?
    let modifiers: Int
    let pressed: Bool?
    let virtualKey: UInt16?
    let result: String

    var reportLine: String {
        let direction = pressed.map { $0 ? "down" : "up" } ?? "state"
        let hid = hidUsage.map(String.init) ?? "unavailable"
        let vk = virtualKey.map(String.init) ?? "unmapped"
        return "#\(sequence) \(source.rawValue); HID \(hid); modifiers \(modifiers); \(direction); VK \(vk); \(result)"
    }
}

@Observable
@MainActor
final class InputDiagnosticStore {
    var isEnabled = false {
        didSet { if !isEnabled { entries.removeAll() } }
    }
    private(set) var entries: [InputDiagnosticEntry] = []
    private var nextSequence = 1

    func observe(
        source: InputDiagnosticSource,
        hidUsage: Int? = nil,
        modifiers: Int = 0,
        pressed: Bool? = nil,
        virtualKey: UInt16? = nil,
        result: String
    ) {
        guard isEnabled else { return }
        entries.append(InputDiagnosticEntry(
            sequence: nextSequence,
            source: source,
            hidUsage: hidUsage,
            modifiers: modifiers,
            pressed: pressed,
            virtualKey: virtualKey,
            result: result
        ))
        nextSequence += 1
        if entries.count > 50 { entries.removeFirst(entries.count - 50) }
    }

    func clear() {
        entries.removeAll()
        nextSequence = 1
    }

    func report(connectionState: String, hostVersion: String? = nil) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let source = Bundle.main.object(forInfoDictionaryKey: "FarRelaySourceRevision") as? String ?? "not embedded"
        return ([
            "FarRelay input diagnostic report",
            "App version: \(version)",
            "TestFlight build: \(build)",
            "Source revision: \(source)",
            "Connection state: \(connectionState)",
            "Host/protocol version: \(hostVersion ?? "unknown")",
            "Events:"
        ] + entries.map(\.reportLine)).joined(separator: "\n")
    }
}

enum InputForwardingResult: Equatable, Sendable {
    case accepted
    case rejected(String)

    var diagnosticText: String {
        switch self {
        case .accepted: "queued for transmission"
        case .rejected(let reason): "rejected: \(reason)"
        }
    }
}
