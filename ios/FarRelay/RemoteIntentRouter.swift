import Observation

/// Selects exactly one semantic target. It never falls through to another
/// target when the selected target is unavailable or does not support intent.
@Observable
@MainActor
final class RemoteIntentRouter {
    private var executors: [RemoteTargetID: any HostTargetExecutor] = [:]
    private(set) var activeTargetID: RemoteTargetID?
    private(set) var lastDecision: RemoteIntentRoutingDecision?

    func register(_ executor: any HostTargetExecutor) {
        executors[executor.target.id] = executor
    }

    func removeTarget(id: RemoteTargetID) {
        executors[id] = nil
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
        guard executors[id] != nil else { return false }
        activeTargetID = id
        return true
    }

    var activeTargetName: String? {
        guard let activeTargetID else { return nil }
        return executors[activeTargetID]?.target.displayName
    }

    func target(for id: RemoteTargetID) -> HostTarget? {
        executors[id]?.target
    }

    func capabilities(for id: RemoteTargetID) -> Set<RemoteCapability>? {
        executors[id]?.target.capabilities
    }

    var activeCapabilities: Set<RemoteCapability> {
        guard let activeTargetID else { return [] }
        return executors[activeTargetID]?.target.capabilities ?? []
    }

    func route(_ intent: RemoteIntent) async -> RemoteIntentResult {
        guard let activeTargetID, let executor = executors[activeTargetID] else {
            lastDecision = .noActiveTarget(intent: intent)
            return .unavailable("No remote target is active.")
        }
        let target = executor.target
        guard target.capabilities.contains(intent.requiredCapability) else {
            lastDecision = .unsupported(
                targetID: target.id,
                intent: intent,
                capability: intent.requiredCapability
            )
            return .unsupported
        }
        lastDecision = .dispatched(targetID: target.id, intent: intent)
        return await executor.perform(intent)
    }
}
