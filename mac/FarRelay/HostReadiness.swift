import AppKit
import Foundation
import Observation

enum MacHostReadiness: String, Equatable, Sendable {
    case disabled
    case starting
    case permissionsRequired
    case voiceOverFeedbackUnavailable
    case inputReady
    case fullMacRemoteReady
    case controllerConnected
    case error

    var label: String {
        switch self {
        case .disabled: "Host disabled"
        case .starting: "Starting"
        case .permissionsRequired: "Permissions required"
        case .voiceOverFeedbackUnavailable: "VoiceOver feedback unavailable"
        case .inputReady: "Input ready"
        case .fullMacRemoteReady: "Full Mac Remote ready"
        case .controllerConnected: "Controller connected"
        case .error: "Error"
        }
    }
}

enum MacFeedbackCapability: String, CaseIterable, Sendable {
    case semanticVoiceOver = "Semantic VoiceOver"
    case systemAudio = "System Audio"
    case minimalFeedback = "Minimal Feedback"
}

struct MacDiagnosticSnapshot: Equatable, Sendable {
    let readiness: MacHostReadiness
    let providerEmbedded: Bool
    let providerEventsReceived: Bool
    let eventCount: Int
    let lastEventAge: TimeInterval?
    let ssmlAvailable: Bool
    let controllerID: String?
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool
    let hostSocketReady: Bool

    func sanitizedReport(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        #if arch(arm64)
        let architecture = "Apple Silicon"
        #elseif arch(x86_64)
        let architecture = "Intel"
        #else
        let architecture = "Unknown Mac architecture"
        #endif
        let eventAge = lastEventAge.map { $0 < 1 ? "less than one second" : "\(Int($0)) seconds" } ?? "none"
        return """
        FarRelay Mac \(version) build \(build)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        \(architecture)

        Remote Voice provider: \(providerEmbedded ? "embedded" : "missing")
        VoiceOver provider events: \(providerEventsReceived ? "yes" : "no")
        Events received: \(eventCount)
        Last event age: \(eventAge)
        SSML: \(ssmlAvailable ? "yes" : "no")
        Accessibility permission: \(accessibilityGranted ? "granted" : "required")
        Input Monitoring permission: \(inputMonitoringGranted ? "granted" : "required")
        Host: \(readiness.label)
        Local host socket: \(hostSocketReady ? "ready" : "not ready")
        Active controller: \(controllerID == nil ? "none" : "connected")
        """
    }
}

@MainActor
@Observable
final class MacHostReadinessModel {
    private(set) var status: MacHostReadiness = .disabled
    private(set) var providerEmbedded = false
    private(set) var voiceOverRunning = false
    private(set) var errorMessage: String?
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "farrelay.macHostEnabled") }
    }

    @ObservationIgnored private let inbox: RemoteSpeechInbox
    @ObservationIgnored private let input: MacRemoteInputEngine

    init(inbox: RemoteSpeechInbox, input: MacRemoteInputEngine) {
        self.inbox = inbox
        self.input = input
        isEnabled = UserDefaults.standard.bool(forKey: "farrelay.macHostEnabled")
        refresh()
    }

    func refresh(socketReady: Bool = false) {
        if let plugIns = Bundle.main.builtInPlugInsURL {
            providerEmbedded = FileManager.default.fileExists(
                atPath: plugIns
                    .appending(path: "FarRelayRemoteVoice.appex", directoryHint: .isDirectory)
                    .path(percentEncoded: false)
            )
        } else {
            providerEmbedded = false
        }
        voiceOverRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.VoiceOver"
        }
        guard isEnabled else {
            status = .disabled
            return
        }
        guard Permissions.hasAccessibility, Permissions.hasInputMonitoring else {
            status = .permissionsRequired
            return
        }
        guard input.permissionState == .granted else {
            status = .permissionsRequired
            return
        }
        guard providerEmbedded else {
            status = .error
            errorMessage = "FarRelay Remote Voice is not embedded in this app. Reinstall FarRelay."
            return
        }
        guard inbox.receivedEventCount > 0 else {
            status = .voiceOverFeedbackUnavailable
            return
        }
        status = socketReady ? .fullMacRemoteReady : .inputReady
    }

    func snapshot(socketReady: Bool, controllerID: String?, lastEventDate: Date?) -> MacDiagnosticSnapshot {
        refresh(socketReady: socketReady)
        return MacDiagnosticSnapshot(
            readiness: controllerID == nil ? status : .controllerConnected,
            providerEmbedded: providerEmbedded,
            providerEventsReceived: inbox.receivedEventCount > 0,
            eventCount: inbox.receivedEventCount,
            lastEventAge: lastEventDate.map { Date().timeIntervalSince($0) },
            ssmlAvailable: inbox.ssmlReceived,
            controllerID: controllerID,
            inputMonitoringGranted: Permissions.hasInputMonitoring,
            accessibilityGranted: Permissions.hasAccessibility,
            hostSocketReady: socketReady
        )
    }
}
