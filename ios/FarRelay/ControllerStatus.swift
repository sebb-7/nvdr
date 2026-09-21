import Foundation
import GameController

enum ControllerBatteryDisplayState: String, Equatable, Sendable {
    case unknown
    case discharging
    case charging
    case full

    init(_ state: GCDeviceBattery.State) {
        switch state {
        case .unknown: self = .unknown
        case .discharging: self = .discharging
        case .charging: self = .charging
        case .full: self = .full
        @unknown default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .unknown: "state unknown"
        case .discharging: "discharging"
        case .charging: "charging"
        case .full: "fully charged"
        }
    }
}

struct ControllerStatusSnapshot: Equatable, Sendable {
    let name: String?
    let batteryPercent: Int?
    let batteryState: ControllerBatteryDisplayState?
    let supportsTouchpad: Bool
    let supportsHaptics: Bool
    let supportsLight: Bool

    static let disconnected = ControllerStatusSnapshot(
        name: nil,
        batteryPercent: nil,
        batteryState: nil,
        supportsTouchpad: false,
        supportsHaptics: false,
        supportsLight: false
    )

    init(
        name: String?,
        batteryPercent: Int?,
        batteryState: ControllerBatteryDisplayState?,
        supportsTouchpad: Bool,
        supportsHaptics: Bool,
        supportsLight: Bool
    ) {
        self.name = name
        self.batteryPercent = batteryPercent
        self.batteryState = batteryState
        self.supportsTouchpad = supportsTouchpad
        self.supportsHaptics = supportsHaptics
        self.supportsLight = supportsLight
    }

    init(controller: GCController) {
        name = controller.vendorName ?? "Controller"
        supportsTouchpad = !controller.physicalInputProfile.touchpads.isEmpty
        supportsHaptics = controller.haptics != nil
        supportsLight = controller.light != nil

        if let battery = controller.battery {
            let state = ControllerBatteryDisplayState(battery.batteryState)
            batteryState = state
            if state == .unknown && battery.batteryLevel == 0 {
                batteryPercent = nil
            } else {
                batteryPercent = Self.percent(fromBatteryLevel: battery.batteryLevel)
            }
        } else {
            batteryPercent = nil
            batteryState = nil
        }
    }

    var isConnected: Bool { name != nil }

    var compactBatteryLabel: String {
        guard isConnected else { return "No controller" }
        guard let batteryPercent else { return "Controller battery unavailable" }
        return "Controller battery \(batteryPercent)%"
    }

    var capabilitiesLabel: String {
        guard isConnected else { return "Controller features unavailable" }
        var features: [String] = []
        if supportsTouchpad { features.append("touchpad") }
        if supportsHaptics { features.append("haptics") }
        if supportsLight { features.append("light") }
        return features.isEmpty
            ? "Controller features: none reported"
            : "Controller features: " + features.joined(separator: ", ")
    }

    var accessibilityLabel: String {
        guard let name else { return "No controller connected" }
        var parts = [name]
        if let batteryPercent {
            parts.append("battery \(batteryPercent) percent")
        } else {
            parts.append("battery unavailable")
        }
        if let batteryState { parts.append(batteryState.label) }
        let featureText = capabilitiesLabel.replacingOccurrences(of: "Controller features: ", with: "")
        parts.append(featureText)
        return parts.joined(separator: ", ")
    }

    static func percent(fromBatteryLevel level: Float) -> Int {
        let clamped = min(max(level, 0), 1)
        return Int((clamped * 100).rounded())
    }
}
