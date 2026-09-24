import Foundation
import Observation

/// A bounded, opt-in trace of remote keyboard handling. It intentionally
/// contains no key characters, credentials, terminal output, or speech.
enum InputDiagnosticSource: String, Sendable {
    case uikitEnvelope = "UIKit press envelope"
    case rawPress = "raw press"
    case keyCommand = "key command"
    case gameControllerRaw = "GCKeyboard raw"
    case gameController = "GCKeyboard"
    case commandFallback = "Command F-key fallback"
    case responder = "responder"
    case controller = "controller"
}

struct InputDiagnosticEntry: Identifiable, Sendable {
    let id = UUID()
    let sequence: Int
    let source: InputDiagnosticSource
    let hidUsage: Int?
    let platformCode: Int?
    let pressType: Int?
    let modifiers: Int
    let pressed: Bool?
    let virtualKey: UInt16?
    let correlationID: Int?
    let controllerInput: ControllerInput?
    let result: String

    var reportLine: String {
        let direction = pressed.map { $0 ? "down" : "up" } ?? "state"
        let hid = hidUsage.map(String.init) ?? "unavailable"
        let vk = virtualKey.map(String.init) ?? "unmapped"
        let correlation = correlationID.map { "; controller event #\($0)" } ?? ""
        let input = controllerInput.map { "; controller:\($0.rawValue)" } ?? ""
        let platform = platformCode.map { "; platform code \($0)" } ?? ""
        let press = pressType.map { "; press type \($0)" } ?? ""
        return "#\(sequence) source=\(source.rawValue)\(correlation)\(input)\(platform)\(press); HID \(hid); modifiers \(modifiers); \(direction); VK \(vk); \(result)"
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
        platformCode: Int? = nil,
        pressType: Int? = nil,
        modifiers: Int = 0,
        pressed: Bool? = nil,
        virtualKey: UInt16? = nil,
        correlationID: Int? = nil,
        controllerInput: ControllerInput? = nil,
        result: String
    ) {
        guard isEnabled else { return }
        entries.append(InputDiagnosticEntry(
            sequence: nextSequence,
            source: source,
            hidUsage: hidUsage,
            platformCode: platformCode,
            pressType: pressType,
            modifiers: modifiers,
            pressed: pressed,
            virtualKey: virtualKey,
            correlationID: correlationID,
            controllerInput: controllerInput,
            result: result
        ))
        nextSequence += 1
        // A full top-row investigation can produce two transitions through
        // multiple APIs for 24 physical gestures (plain F1-F12 + Fn+F1-F12).
        // Keep enough history to preserve the beginning and end of one sweep.
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }

    func clear() {
        entries.removeAll()
        nextSequence = 1
    }

    /// The controller path is deliberately separate from responder and
    /// GCKeyboard records so a physical gamepad reception can be proven from
    /// the copied report.
    func observeController(
        eventID: Int,
        input: ControllerInput,
        pressed: Bool? = nil,
        stage: String
    ) {
        observe(
            source: .controller,
            pressed: pressed,
            correlationID: eventID,
            controllerInput: input,
            result: stage
        )
    }

    func report(
        connectionState: String,
        hostVersion: String? = nil,
        hostInputEvidence: [String] = []
    ) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let source = Bundle.main.object(forInfoDictionaryKey: "FarRelaySourceRevision") as? String ?? "not embedded"
        var lines = [
            "FarRelay input diagnostic report",
            "App version: \(version)",
            "TestFlight build: \(build)",
            "Source revision: \(source)",
            "Connection state: \(connectionState)",
            "Host/protocol version: \(hostVersion ?? "unknown")",
            "Transport delivery: see per-event routing and transport stages below",
            "Capture coverage: UIKit envelopes include presses with no UIKey; GCKeyboard raw includes mapped and unmapped key codes.",
            "Media command handlers: diagnostics do not register MPRemoteCommandCenter handlers because doing so would change system media-key ownership.",
            "Events:"
        ]
        lines += entries.map(\.reportLine)
        if hostInputEvidence.isEmpty == false {
            lines.append("Host input evidence (existing IPC stderr; NVDA execution unconfirmed):")
            lines += hostInputEvidence
        }
        return lines.joined(separator: "\n")
    }
}

enum InputForwardingResult: Equatable, Sendable {
    case accepted
    case rejected(String)

    var diagnosticText: String {
        switch self {
        case .accepted: "queued for transport write; host receipt unconfirmed"
        case .rejected(let reason): "rejected: \(reason)"
        }
    }
}
