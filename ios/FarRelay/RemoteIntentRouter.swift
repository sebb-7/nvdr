import Foundation
import Observation

/// Selects exactly one semantic target. It never falls through to another
/// target when the selected target is unavailable or does not support intent.
@Observable
@MainActor
final class RemoteIntentRouter {
    private struct Registration {
        let id = UUID()
        let executor: any HostTargetExecutor
    }

    private var registrations: [RemoteTargetID: Registration] = [:]
    private(set) var activeTargetID: RemoteTargetID?
    private(set) var lastDecision: RemoteIntentRoutingDecision?

    func register(_ executor: any HostTargetExecutor) {
        registrations[executor.target.id] = Registration(executor: executor)
    }

    func removeTarget(id: RemoteTargetID) {
        registrations[id] = nil
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
        guard registrations[id] != nil else { return false }
        activeTargetID = id
        return true
    }

    var activeTargetName: String? {
        guard let activeTargetID else { return nil }
        return registrations[activeTargetID]?.executor.target.displayName
    }

    func target(for id: RemoteTargetID) -> HostTarget? {
        registrations[id]?.executor.target
    }

    func capabilities(for id: RemoteTargetID) -> Set<RemoteCapability>? {
        registrations[id]?.executor.target.capabilities
    }

    var activeCapabilities: Set<RemoteCapability> {
        guard let activeTargetID else { return [] }
        return registrations[activeTargetID]?.executor.target.capabilities ?? []
    }

    /// Capture this only for a stateful input lifecycle. Stateless commands
    /// continue to resolve the selected target at send time.
    func routeLease(for targetID: RemoteTargetID) -> RemoteIntentRoute? {
        guard let registration = registrations[targetID] else { return nil }
        return RemoteIntentRoute(targetID: targetID, registrationID: registration.id)
    }

    func target(for route: RemoteIntentRoute) -> HostTarget? {
        guard let registration = registrations[route.targetID], registration.id == route.registrationID else {
            return nil
        }
        return registration.executor.target
    }

    func route(_ intent: RemoteIntent) async -> RemoteIntentResult {
        guard let activeTargetID else {
            lastDecision = .noActiveTarget(intent: intent)
            return .unavailable("No remote target is active.")
        }
        return await route(intent, to: activeTargetID)
    }

    /// Delivers a lifecycle continuation to the target which accepted its
    /// press. This prevents a later target selection from receiving an
    /// unrelated release and leaving the original target's key held.
    func route(_ intent: RemoteIntent, to targetID: RemoteTargetID) async -> RemoteIntentResult {
        guard let executor = registrations[targetID]?.executor else {
            lastDecision = .noActiveTarget(intent: intent)
            return .unavailable("The original remote target is no longer available.")
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

    /// Delivers a lifecycle continuation only to the exact registration that
    /// accepted its initial press. A same-ID replacement fails closed.
    func route(_ intent: RemoteIntent, via route: RemoteIntentRoute) async -> RemoteIntentResult {
        guard let registration = registrations[route.targetID], registration.id == route.registrationID else {
            lastDecision = .originalRegistrationUnavailable(targetID: route.targetID, intent: intent)
            return .unavailable("The original remote target registration is no longer available.")
        }
        let target = registration.executor.target
        guard target.capabilities.contains(intent.requiredCapability) else {
            lastDecision = .unsupported(targetID: target.id, intent: intent, capability: intent.requiredCapability)
            return .unsupported
        }
        lastDecision = .dispatched(targetID: target.id, intent: intent)
        return await registration.executor.perform(intent)
    }
}
