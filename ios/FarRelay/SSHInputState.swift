import Foundation

/// Tracks keys accepted by the current remote input channel. Resetting this
/// state on a disconnect prevents a late key-up from a previous channel from
/// being replayed into the newly established remote session.
struct SSHInputState: Sendable, Equatable {
    private(set) var pressedKeys: Set<UInt16> = []

    mutating func command(forKey vk: UInt16, pressed: Bool) -> IPCCommand? {
        if pressed {
            // UIKit emits repeated key-down events while a hardware key is
            // held. Preserve every one: the remote desktop relies on those
            // transitions for normal text editing and navigation repeat.
            pressedKeys.insert(vk)
        } else {
            guard pressedKeys.remove(vk) != nil else { return nil }
        }
        return .key(vk: vk, pressed: pressed)
    }

    mutating func reset() {
        pressedKeys.removeAll()
    }
}
