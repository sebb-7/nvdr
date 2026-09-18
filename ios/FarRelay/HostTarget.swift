import Foundation

/// A stable, inspectable control target. Transport and controller references
/// remain with its executor so this value can be safely presented to adapters.
struct HostTarget: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case nvdaRemote
        case sshTerminal
        case macRemote
    }

    let id: RemoteTargetID
    let displayName: String
    let profileID: UUID?
    let sessionID: UUID?
    let platform: HostPlatform
    let kind: Kind
    let connectionState: ConnectionState
    let capabilities: Set<RemoteCapability>

    enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case ready
        case unavailable(String)
    }
}

/// The only object that holds controller or transport references for a target.
/// A router selects this executor explicitly; it never initiates a connection,
/// requests a lease, or falls back to another executor.
@MainActor
protocol HostTargetExecutor: AnyObject {
    var target: HostTarget { get }

    func perform(_ intent: RemoteIntent) async -> RemoteIntentResult
}

/// A small diagnostic record for the last routing decision. It deliberately
/// records selection and capability rejection without exposing controller or
/// transport details.
enum RemoteIntentRoutingDecision: Equatable, Sendable {
    case noActiveTarget(intent: RemoteIntent)
    case unsupported(targetID: RemoteTargetID, intent: RemoteIntent, capability: RemoteCapability)
    case dispatched(targetID: RemoteTargetID, intent: RemoteIntent)
}
