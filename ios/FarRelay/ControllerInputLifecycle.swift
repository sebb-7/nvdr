import Foundation

/// A deterministic, hardware-independent view of controller input state.
/// The adapter feeds it button and analog transitions; it owns no controller
/// objects and can therefore be tested without a paired controller.
enum ControllerInputPhase: Equatable, Sendable {
    case pressed(ControllerInput)
    case repeated(ControllerInput)
    case released(ControllerInput)
}

struct ControllerInputLifecycle: Sendable {
    static let initialRepeatDelay: TimeInterval = 0.35
    static let repeatInterval: TimeInterval = 0.08

    private var pressedInputs: Set<ControllerInput> = []
    private var nextRepeatAt: [ControllerInput: TimeInterval] = [:]

    mutating func receive(
        _ input: ControllerInput,
        pressed: Bool,
        at time: TimeInterval
    ) -> [ControllerInputPhase] {
        if pressed {
            guard pressedInputs.insert(input).inserted else { return [] }
            nextRepeatAt[input] = time + Self.initialRepeatDelay
            return [.pressed(input)]
        }

        guard pressedInputs.remove(input) != nil else { return [] }
        nextRepeatAt[input] = nil
        return [.released(input)]
    }

    mutating func repeatEvents(at time: TimeInterval) -> [ControllerInputPhase] {
        ControllerInput.allCases.compactMap { input in
            guard pressedInputs.contains(input), let next = nextRepeatAt[input], time >= next else { return nil }
            // Emit at most one repeat per scheduler tick. This avoids a burst
            // when the app was suspended or the main actor was briefly busy.
            nextRepeatAt[input] = time + Self.repeatInterval
            return .repeated(input)
        }
    }

    mutating func releaseAll() -> [ControllerInputPhase] {
        let events = ControllerInput.allCases.compactMap { input in
            pressedInputs.contains(input) ? ControllerInputPhase.released(input) : nil
        }
        pressedInputs.removeAll()
        nextRepeatAt.removeAll()
        return events
    }
}

/// Converts one analog stick into stable cardinal input phases. Pressing uses
/// a larger threshold than releasing, so minor motion around a boundary cannot
/// oscillate a mapped remote key.
struct ControllerStickDirectionClassifier: Sendable {
    static let pressThreshold: Float = 0.65
    static let releaseThreshold: Float = 0.45

    private let left: ControllerInput
    private let right: ControllerInput
    private let up: ControllerInput
    private let down: ControllerInput
    private var active: Set<ControllerInput> = []

    init(left: ControllerInput, right: ControllerInput, up: ControllerInput, down: ControllerInput) {
        self.left = left
        self.right = right
        self.up = up
        self.down = down
    }

    mutating func update(x: Float, y: Float, at _: TimeInterval) -> [ControllerInputPhase] {
        let values: [(ControllerInput, Float)] = [(left, -x), (right, x), (up, y), (down, -y)]
        let changes = values.compactMap { input, value -> (ControllerInput, Bool)? in
            let wasActive = active.contains(input)
            let isActive = value >= (wasActive ? Self.releaseThreshold : Self.pressThreshold)
            return isActive == wasActive ? nil : (input, isActive)
        }
        // Release an opposing direction before pressing its replacement.
        let releases = changes.filter { !$0.1 }.map { input, _ -> ControllerInputPhase in
            active.remove(input)
            return .released(input)
        }
        let presses = changes.filter { $0.1 }.map { input, _ -> ControllerInputPhase in
            active.insert(input)
            return .pressed(input)
        }
        return releases + presses
    }

    mutating func reset() { active.removeAll() }
}
