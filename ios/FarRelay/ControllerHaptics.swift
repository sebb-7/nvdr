import CoreHaptics
import GameController

enum ControllerHapticCue: Sendable {
    case selection
    case boundary
    case quickNavigationCompleted
}

@MainActor
final class ControllerHapticFeedback {
    private var engine: CHHapticEngine?

    func attach(to controller: GCController) {
        detach()
        guard let haptics = controller.haptics,
              haptics.supportedLocalities.contains(.default) else {
            return
        }

        guard let engine = haptics.createEngine(withLocality: .default) else {
            return
        }
        engine.playsHapticsOnly = true

        do {
            try engine.start()
            self.engine = engine
        } catch {
            self.engine = nil
        }
    }

    func detach() {
        engine?.stop(completionHandler: nil)
        engine = nil
    }

    func play(_ cue: ControllerHapticCue) {
        guard let engine else { return }

        let events: [CHHapticEvent]
        switch cue {
        case .selection:
            events = [
                transient(intensity: 0.35, sharpness: 0.65, time: 0)
            ]
        case .boundary:
            events = [
                transient(intensity: 0.75, sharpness: 0.45, time: 0),
                transient(intensity: 0.75, sharpness: 0.45, time: 0.09)
            ]
        case .quickNavigationCompleted:
            events = [
                transient(intensity: 0.5, sharpness: 0.75, time: 0),
                transient(intensity: 0.5, sharpness: 0.75, time: 0.08)
            ]
        }

        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics are supplementary. Input and navigation must continue
            // normally if the controller or system rejects a haptic request.
        }
    }

    private func transient(
        intensity: Float,
        sharpness: Float,
        time: TimeInterval
    ) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                .init(parameterID: .hapticIntensity, value: intensity),
                .init(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: time
        )
    }
}
