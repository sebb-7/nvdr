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
