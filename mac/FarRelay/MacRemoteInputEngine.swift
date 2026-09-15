@preconcurrency import CoreGraphics
import Foundation
import Observation

/// Supported event-source marker used to prevent FarRelay-generated target
/// input from being re-captured by this Mac when it is also a controller.
enum FarRelaySyntheticEvent {
    static let marker: Int64 = 0x4652_4C59

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    static func isFarRelayEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}

@MainActor
@Observable
final class MacRemoteInputEngine {
    enum PermissionState: Equatable {
        case unknown
        case granted
        case denied
    }

    private(set) var permissionState: PermissionState = .unknown
    private(set) var lease = RemoteKeyLease()

    @ObservationIgnored private let postEvent: (CGEvent) -> Void

    init(postEvent: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.postEvent = postEvent
        recheckPermission()
    }

    func recheckPermission() {
        permissionState = CGPreflightPostEventAccess() ? .granted : .denied
    }

    func requestPermission() {
        permissionState = CGRequestPostEventAccess() ? .granted : .denied
    }

    func requestControl(controllerID: String) -> RemoteKeyLeaseResult {
        lease.requestControl(controllerID)
    }

    func handle(_ event: RemoteKeyEvent) -> RemoteKeyAcceptance {
        guard permissionState == .granted else { return .rejected }
        let acceptance = lease.accept(event)
        guard case .accepted(let acceptedEvent) = acceptance else { return acceptance }
        post(acceptedEvent)
        return acceptance
    }

    func releaseControl(controllerID: String) {
        release(lease.releaseControl(controllerID: controllerID))
    }

    func revokeControl() {
        release(lease.revoke())
    }

    private func release(_ events: [RemoteKeyEvent]) {
        events.forEach(post)
    }

    private func post(_ event: RemoteKeyEvent) {
        guard let keyCode = MacRemoteKeyMap.keyCode(for: event.key) else { return }
        guard let cgEvent = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .hidSystemState),
            virtualKey: keyCode,
            keyDown: event.isPressed
        ) else {
            return
        }
        FarRelaySyntheticEvent.mark(cgEvent)
        postEvent(cgEvent)
    }
}

enum MacRemoteKeyMap {
    static func keyCode(for key: RemoteKey) -> CGKeyCode? {
        let letterKeyCodes: [CGKeyCode] = [
            0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
            45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
        ]
        if (0x04...0x1D).contains(key.rawValue) {
            return letterKeyCodes[Int(key.rawValue - 0x04)]
        }
        let keyCodes: [UInt16: CGKeyCode] = [
            0x1E: 18, 0x1F: 19, 0x20: 20, 0x21: 21, 0x22: 23,
            0x23: 22, 0x24: 26, 0x25: 28, 0x26: 25, 0x27: 29,
            0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49,
            0x2D: 27, 0x2E: 24, 0x2F: 33, 0x30: 30, 0x31: 42,
            0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43, 0x37: 47,
            0x38: 44, 0x39: 57,
            0x3A: 122, 0x3B: 120, 0x3C: 99, 0x3D: 118, 0x3E: 96,
            0x3F: 97, 0x40: 98, 0x41: 100, 0x42: 101, 0x43: 109,
            0x44: 103, 0x45: 111,
            0x49: 114, 0x4A: 115, 0x4B: 116, 0x4C: 117, 0x4D: 119,
            0x4E: 121, 0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126,
            0xE0: 59, 0xE1: 56, 0xE2: 58, 0xE3: 55,
            0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54,
        ]
        return keyCodes[key.rawValue]
    }
}
