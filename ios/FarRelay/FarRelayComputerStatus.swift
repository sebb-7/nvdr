import Foundation

/// Profile-scoped connection truth for the saved-computer list. A bridge can
/// serve only one profile at a time; a state from that bridge must never leak
/// onto another saved computer's row.
@MainActor
struct FarRelayComputerStatus: Equatable {
    enum Connection: Equatable {
        case disconnected
        case connecting
        case authenticating
        case relayConnected
        case waitingForNVDA
        case ready
        case reconnecting(Int)
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: "Disconnected"
            case .connecting: "Connecting"
            case .authenticating: "Authenticating"
            case .relayConnected: "Relay connected"
            case .waitingForNVDA: "Waiting for NVDA"
            case .ready: "NVDA connected"
            case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))"
            case .failed: "Connection failed"
            }
        }

        var action: NVDARemoteConnectionAction {
            switch self {
            case .disconnected, .failed: .connect
            case .connecting, .authenticating, .reconnecting: .cancel
            case .relayConnected, .waitingForNVDA, .ready: .disconnect
            }
        }
    }

    let connection: Connection
    let nvdaSummary: String
    let terminalSummary: String
    let detail: String
    let controller: String

    private let reportPrimary: String?
    private let reportNVDA: String?

    init(
        connection: Connection,
        nvdaSummary: String,
        terminalSummary: String,
        detail: String,
        controller: String = "Remote Control: \(ControllerLeaseState.legacyUnleased.statusLabel)"
    ) {
        self.connection = connection
        self.nvdaSummary = nvdaSummary
        self.terminalSummary = terminalSummary
        self.detail = detail
        self.controller = controller
        reportPrimary = nil
        reportNVDA = nil
    }

    /// Retains the status-report fixture API while the application uses the
    /// profile-scoped connection model above as its single source of truth.
    init(primary: String, detail: String, nvda: String, terminalSummary: String, controller: String) {
        connection = .disconnected
        nvdaSummary = nvda
        self.terminalSummary = terminalSummary
        self.detail = detail
        self.controller = controller
        reportPrimary = primary
        reportNVDA = nvda
    }

    var primary: String {
        if let reportPrimary { return reportPrimary }
        return switch connection {
        case .disconnected: "Disconnected"
        case .connecting, .authenticating: "Connecting"
        case .relayConnected, .ready: "Connected"
        case .waitingForNVDA: "Waiting for NVDA"
        case .reconnecting: "Connection lost"
        case .failed: "Connection failed"
        }
    }

    var nvda: String {
        if let reportNVDA { return reportNVDA }
        if nvdaSummary == "NVDA Remote is not configured" { return "NVDA: unsupported" }
        return switch connection {
        case .disconnected: "NVDA: not connected"
        case .connecting, .authenticating: "NVDA: waiting"
        case .relayConnected: "NVDA: relay connected"
        case .waitingForNVDA: "NVDA: waiting for NVDA"
        case .ready: "NVDA: ready"
        case .reconnecting: "NVDA: reconnecting"
        case .failed: "NVDA: unavailable"
        }
    }

    var accessibilityLabel: String {
        "\(connection.label). \(nvdaSummary). \(terminalSummary). \(detail)"
    }

    static func derive(
        profile: HostProfile,
        bridge: BridgeClient,
        terminals: TerminalSessionManager
    ) -> Self {
        let terminalCount = terminals.activeSessionCount(for: profile.id)
        let terminalSummary = terminalCount == 1 ? "1 terminal active" : "\(terminalCount) terminals active"

        // Only the bridge's active profile may report a remote-control state.
        guard bridge.activeProfileID == profile.id else {
            return Self(
                connection: .disconnected,
                nvdaSummary: profile.isNVDARemoteEnabled ? "NVDA not connected" : "NVDA Remote is not configured",
                terminalSummary: terminalSummary,
                detail: terminals.hasActiveConnection(for: profile.id)
                    ? "A terminal is connected; remote control is disconnected"
                    : "No active remote-control connection"
            )
        }

        let connection: Connection
        let nvdaSummary: String
        let detail: String
        switch bridge.status {
        case .idle, .disconnected:
            connection = .disconnected
            nvdaSummary = "NVDA not connected"
            detail = "No active remote-control connection"
        case .connecting:
            connection = .connecting
            nvdaSummary = "NVDA waiting"
            detail = "Starting the SSH connection"
        case .authenticating:
            connection = .authenticating
            nvdaSummary = "NVDA waiting"
            detail = "Authenticating with the computer"
        case .relayConnected:
            connection = .relayConnected
            nvdaSummary = "NVDA relay connected"
            detail = "Waiting for the NVDA endpoint"
        case .waitingForNVDA, .nvdaNotConnected:
            connection = .waitingForNVDA
            nvdaSummary = "NVDA waiting"
            detail = "SSH is connected, but NVDA is not ready"
        case .ready:
            connection = .ready
            nvdaSummary = "NVDA ready"
            detail = "Remote keyboard input is available when forwarding is on"
        case .reconnecting(let attempt):
            connection = .reconnecting(attempt)
            nvdaSummary = "NVDA reconnecting"
            detail = "Remote keyboard input is paused"
        case .failed(let message):
            connection = .failed(RemoteLaunchDiagnostics.sanitizedReason(message))
            nvdaSummary = "NVDA unavailable"
            detail = RemoteLaunchDiagnostics.sanitizedReason(message)
        }
        return Self(connection: connection, nvdaSummary: nvdaSummary, terminalSummary: terminalSummary, detail: detail)
    }
}
