import Foundation

/// Stable USB HID Keyboard/Keypad usage ID. Physical keys are transported as
/// usages, not Windows virtual-key values; text insertion remains a separate
/// future protocol operation.
struct RemoteKey: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    let rawValue: UInt16

    init?(rawValue: UInt16) {
        guard (0x04...0xE7).contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(uncheckedUsage: UInt16) {
        rawValue = uncheckedUsage
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static let a = RemoteKey(uncheckedUsage: 0x04)
    static let z = RemoteKey(uncheckedUsage: 0x1D)
    static let returnKey = RemoteKey(uncheckedUsage: 0x28)
    static let escape = RemoteKey(uncheckedUsage: 0x29)
    static let deleteBackward = RemoteKey(uncheckedUsage: 0x2A)
    static let tab = RemoteKey(uncheckedUsage: 0x2B)
    static let space = RemoteKey(uncheckedUsage: 0x2C)
    static let capsLock = RemoteKey(uncheckedUsage: 0x39)
    static let f1 = RemoteKey(uncheckedUsage: 0x3A)
    static let f12 = RemoteKey(uncheckedUsage: 0x45)
    static let home = RemoteKey(uncheckedUsage: 0x4A)
    static let pageUp = RemoteKey(uncheckedUsage: 0x4B)
    static let forwardDelete = RemoteKey(uncheckedUsage: 0x4C)
    static let end = RemoteKey(uncheckedUsage: 0x4D)
    static let pageDown = RemoteKey(uncheckedUsage: 0x4E)
    static let rightArrow = RemoteKey(uncheckedUsage: 0x4F)
    static let leftArrow = RemoteKey(uncheckedUsage: 0x50)
    static let downArrow = RemoteKey(uncheckedUsage: 0x51)
    static let upArrow = RemoteKey(uncheckedUsage: 0x52)
    static let leftControl = RemoteKey(uncheckedUsage: 0xE0)
    static let leftShift = RemoteKey(uncheckedUsage: 0xE1)
    static let leftOption = RemoteKey(uncheckedUsage: 0xE2)
    static let leftCommand = RemoteKey(uncheckedUsage: 0xE3)
    static let rightControl = RemoteKey(uncheckedUsage: 0xE4)
    static let rightShift = RemoteKey(uncheckedUsage: 0xE5)
    static let rightOption = RemoteKey(uncheckedUsage: 0xE6)
    static let rightCommand = RemoteKey(uncheckedUsage: 0xE7)
}

struct RemoteKeyEvent: Equatable, Sendable {
    let controllerID: String
    let generation: UInt64
    let key: RemoteKey
    let isPressed: Bool
}

enum RemoteKeyLeaseResult: Equatable, Sendable {
    case granted(generation: UInt64)
    case busy
}

enum RemoteKeyAcceptance: Equatable, Sendable {
    case accepted(RemoteKeyEvent)
    case rejected
}

/// Target-side single-controller lease and held-key ownership. This is pure
/// policy so it can be exhaustively tested without TCC or a real keyboard.
struct RemoteKeyLease {
    private(set) var controllerID: String?
    private(set) var generation: UInt64 = 0
    private var heldKeys: Set<RemoteKey> = []

    mutating func requestControl(_ requestedControllerID: String) -> RemoteKeyLeaseResult {
        guard !requestedControllerID.isEmpty else { return .busy }
        if let controllerID, controllerID != requestedControllerID {
            return .busy
        }
        if controllerID == nil {
            generation &+= 1
            self.controllerID = requestedControllerID
            heldKeys.removeAll()
        }
        return .granted(generation: generation)
    }

    mutating func accept(_ event: RemoteKeyEvent) -> RemoteKeyAcceptance {
        guard event.controllerID == controllerID, event.generation == generation else {
            return .rejected
        }
        if event.isPressed {
            heldKeys.insert(event.key)
        } else {
            heldKeys.remove(event.key)
        }
        return .accepted(event)
    }

    mutating func releaseControl(controllerID: String) -> [RemoteKeyEvent] {
        guard controllerID == self.controllerID else { return [] }
        return clearHeldKeys()
    }

    mutating func revoke() -> [RemoteKeyEvent] {
        return clearHeldKeys()
    }

    private mutating func clearHeldKeys() -> [RemoteKeyEvent] {
        let released = heldKeys.sorted().compactMap { key -> RemoteKeyEvent? in
            guard let controllerID else { return nil }
            return RemoteKeyEvent(
                controllerID: controllerID,
                generation: generation,
                key: key,
                isPressed: false
            )
        }
        heldKeys.removeAll()
        controllerID = nil
        generation &+= 1
        return released
    }
}
