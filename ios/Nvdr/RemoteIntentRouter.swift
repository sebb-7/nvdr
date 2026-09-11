import Observation

/// Selects exactly one semantic target. It never falls through to another
/// target when the selected target is unavailable or does not support intent.
@Observable
@MainActor
final class RemoteIntentRouter {
    private var targets: [RemoteTargetID: any RemoteIntentTarget] = [:]
    private(set) var activeTargetID: RemoteTargetID?

    func register(_ target: any RemoteIntentTarget) {
        targets[target.remoteTargetID] = target
    }

    func removeTarget(id: RemoteTargetID) {
        targets[id] = nil
        if activeTargetID == id {
            activeTargetID = nil
        }
    }

    @discardableResult
    func setActiveTarget(id: RemoteTargetID?) -> Bool {
        guard let id else {
            activeTargetID = nil
            return true
        }
        guard targets[id] != nil else { return false }
        activeTargetID = id
        return true
    }

    var activeTargetName: String? {
        guard let activeTargetID else { return nil }
        return targets[activeTargetID]?.remoteTargetName
    }

    func capabilities(for id: RemoteTargetID) -> Set<RemoteCapability>? {
        targets[id]?.capabilities
    }

    var activeCapabilities: Set<RemoteCapability> {
        guard let activeTargetID else { return [] }
        return targets[activeTargetID]?.capabilities ?? []
    }

    func route(_ intent: RemoteIntent) async -> RemoteIntentResult {
        guard let activeTargetID, let target = targets[activeTargetID] else {
            return .unavailable("No remote target is active.")
        }
        guard target.capabilities.contains(intent.requiredCapability) else {
            return .unsupported
        }
        return await target.perform(intent)
    }
}
