import Foundation
import Observation

/// Values advertised by a compatible FarRelay Host. Unknown values deliberately
/// remain representable so a newer host never crashes an older client.
struct FarRelayCapability: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    static let terminal = Self(rawValue: "terminal")
    static let nvdaRemote = Self(rawValue: "nvda.remote")
    static let remoteInput = Self(rawValue: "remoteInput")
    static let controllerLease = Self(rawValue: "controllerLease")
    static let speechEvents = Self(rawValue: "speechEvents")
    static let macRemote = Self(rawValue: "macRemote")
    static let voiceOverSemanticFeedback = Self(rawValue: "voiceOverSemanticFeedback")
}

/// A snapshot is runtime evidence, not a platform-name inference. It is safe to
/// persist only as a diagnostic hint; action gating must use the current session.
struct FarRelayCapabilitySnapshot: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let hostVersion: String
    let platform: HostPlatform
    let capabilities: Set<FarRelayCapability>

    func supports(_ capability: FarRelayCapability) -> Bool {
        capabilities.contains(capability)
    }
}

extension HostCapabilities {
    func capabilitySnapshot(platform: HostPlatform) -> FarRelayCapabilitySnapshot {
        FarRelayCapabilitySnapshot(
            protocolVersion: protocolVersion,
            hostVersion: hostVersion,
            platform: platform,
            capabilities: advertisedFeatures
        )
    }
}

enum FarRelayCompatibility: Equatable, Sendable {
    case compatible
    case incompatibleProtocol(expected: Int, received: Int)

    /// Major protocol mismatches fail closed. A matching major accepts an
    /// unknown optional capability as an inert extension.
    static func evaluate(clientProtocol: Int, hostProtocol: Int) -> Self {
        clientProtocol == hostProtocol
            ? .compatible
            : .incompatibleProtocol(expected: clientProtocol, received: hostProtocol)
    }
}

enum ControllerLeaseState: Equatable, Sendable {
    case unavailable
    case none
    case requested
    case granted(controllerID: UUID, generation: Int)
    case busy
    case released
    case lost
    /// Legacy IPC has no authoritative cross-device lease. It is intentionally
    /// distinct from granted and must not be presented as ownership truth.
    case legacyUnleased

    var statusLabel: String {
        switch self {
        case .unavailable: "Unsupported"
        case .none: "Available"
        case .requested: "Requesting control"
        case .granted: "Controlled by this device"
        case .busy: "In use by another FarRelay device"
        case .released: "Released"
        case .lost: "Control lost"
        case .legacyUnleased: "Legacy host: ownership unavailable"
        }
    }
}

/// Pure generation gate for a future authoritative host lease. It ensures a
/// delayed prior controller can never regain the right to send input locally.
struct ControllerLeaseGate: Equatable, Sendable {
    private(set) var state: ControllerLeaseState = .none
    private(set) var generation = 0

    mutating func request() {
        guard state != .busy else { return }
        state = .requested
    }

    mutating func grant(controllerID: UUID) {
        generation += 1
        state = .granted(controllerID: controllerID, generation: generation)
    }

    mutating func lose() {
        generation += 1
        state = .lost
    }

    mutating func release() {
        generation += 1
        state = .released
    }

    func allowsInput(controllerID: UUID, generation: Int) -> Bool {
        guard case let .granted(owner, currentGeneration) = state else { return false }
        return owner == controllerID && currentGeneration == generation
    }
}

enum FarRelayEventSeverity: String, Codable, CaseIterable, Sendable {
    case informational
    case warning
    case critical
}

enum FarRelayEventCategory: String, Codable, Sendable {
    case connectivity
    case remoteInput
    case nvda
    case persistence
    case compatibility
}

enum FarRelayEventCode: String, Codable, Sendable {
    case connectionLost
    case connectionFailed
    case nvdaDisconnected
    case controllerLeaseLost
    case profileMigrationFailed
    case profileStoreWriteFailed
    case incompatibleProtocol
}

struct FarRelayEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let severity: FarRelayEventSeverity
    let category: FarRelayEventCategory
    let profileID: UUID?
    let connectionGeneration: Int?
    let code: FarRelayEventCode
    let summary: String
    let safeDetail: String
    let recommendedAction: String
    let deduplicationKey: String
    var occurrenceCount: Int

    init(
        severity: FarRelayEventSeverity,
        category: FarRelayEventCategory,
        profileID: UUID? = nil,
        connectionGeneration: Int? = nil,
        code: FarRelayEventCode,
        summary: String,
        safeDetail: String,
        recommendedAction: String,
        deduplicationKey: String
    ) {
        id = UUID()
        timestamp = .now
        self.severity = severity
        self.category = category
        self.profileID = profileID
        self.connectionGeneration = connectionGeneration
        self.code = code
        self.summary = summary
        self.safeDetail = safeDetail
        self.recommendedAction = recommendedAction
        self.deduplicationKey = deduplicationKey
        occurrenceCount = 1
    }
}

/// Bounded in-app history. Event text is authored from fixed safe copy; raw
/// transport errors, typed content, relay channels, and speech are never stored.
@Observable
@MainActor
final class FarRelayEventStore {
    private(set) var events: [FarRelayEvent] = []
    private(set) var lastAnnounceableEventID: UUID?
    private let capacity: Int

    init(capacity: Int = 50) { self.capacity = max(1, capacity) }

    func emit(_ event: FarRelayEvent) {
        if let index = events.firstIndex(where: { $0.deduplicationKey == event.deduplicationKey }) {
            var existing = events[index]
            existing.occurrenceCount += 1
            events[index] = existing
            return
        }
        events.insert(event, at: 0)
        if events.count > capacity { events.removeLast(events.count - capacity) }
        if event.severity == .critical { lastAnnounceableEventID = event.id }
    }

    var criticalEvents: [FarRelayEvent] {
        events.filter { $0.severity == .critical }
    }
}

@MainActor
struct FarRelayComputerStatus: Equatable {
    let primary: String
    let detail: String
    let nvda: String
    let terminalSummary: String
    let controller: String

    static func derive(
        profile: HostProfile,
        bridge: BridgeClient,
        terminals: TerminalSessionManager
    ) -> Self {
        let terminalCount = terminals.activeSessionCount(for: profile.id)
        let terminalSummary = terminalCount == 1 ? "1 terminal active" : "\(terminalCount) terminals active"
        guard bridge.activeProfileID == profile.id else {
            return Self(
                primary: terminals.hasActiveConnection(for: profile.id) ? "Connected" : "Disconnected",
                detail: terminals.hasActiveConnection(for: profile.id) ? "Terminal transport available" : "No active transport",
                nvda: profile.isNVDARemoteEnabled ? "NVDA: not connected" : "NVDA: unsupported",
                terminalSummary: terminalSummary,
                controller: "Remote Control: \(ControllerLeaseState.unavailable.statusLabel)"
            )
        }

        let (primary, detail, nvda): (String, String, String) = switch bridge.status {
        case .idle: ("Disconnected", "No active transport", "NVDA: not connected")
        case .connecting, .authenticating: ("Connecting", "SSH connection in progress", "NVDA: waiting")
        case .reconnecting: ("Connection lost", "Reconnecting", "NVDA: reconnecting")
        case .relayConnected: ("Connected", "SSH connected", "NVDA: relay connected")
        case .waitingForNVDA, .nvdaNotConnected: ("Waiting for NVDA", "SSH connected", "NVDA: waiting for NVDA")
        case .ready: ("Connected", "SSH connected", "NVDA: ready")
        case .disconnected: ("Disconnected", "Transport stopped", "NVDA: not connected")
        case .failed: ("Connection failed", "Open Diagnostics", "NVDA: unavailable")
        }
        return Self(
            primary: primary,
            detail: detail,
            nvda: nvda,
            terminalSummary: terminalSummary,
            controller: "Remote Control: \(ControllerLeaseState.legacyUnleased.statusLabel)"
        )
    }
}

@MainActor
enum FarRelayStatusReport {
    static func make(profile: HostProfile, status: FarRelayComputerStatus, events: [FarRelayEvent]) -> String {
        let codes = events.prefix(5).map(\.code.rawValue).joined(separator: ", ")
        return [
            "FarRelay status report",
            "Computer: \(profile.displayName)",
            "Platform: \(profile.platform.label)",
            "Connection: \(status.primary)",
            "Health: \(status.detail)",
            status.nvda,
            status.terminalSummary,
            status.controller,
            "Recent critical events: \(codes.isEmpty ? "none" : codes)"
        ].joined(separator: "\n")
    }
}
