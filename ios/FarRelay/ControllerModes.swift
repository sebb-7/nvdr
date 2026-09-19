import Foundation

/// Deterministic local state machine for Options. It deliberately emits no
/// remote input: callers ask which layer resolves a subsequent controller
/// input, ensuring a layer gesture can never accidentally invoke Base.
struct ControllerLayerEngine: Sendable {
    enum State: Equatable, Sendable {
        case base
        case holding(String)
        case oneShot(String)
        case locked(String)
    }

    private(set) var state: State = .base
    private var pressedLayerID: String?
    private var pressStartedAt: TimeInterval?
    private var lastTapAt: TimeInterval?
    private let doubleTapWindow: TimeInterval

    init(doubleTapWindow: TimeInterval = 0.35) {
        self.doubleTapWindow = doubleTapWindow
    }

    mutating func press(layerID: String, at time: TimeInterval) {
        if case .locked(let lockedID) = state, lockedID == layerID {
            state = .base
            lastTapAt = nil
            return
        }
        pressedLayerID = layerID
        pressStartedAt = time
    }

    mutating func release(layerID: String, at time: TimeInterval) {
        guard pressedLayerID == layerID else { return }
        defer { pressedLayerID = nil; pressStartedAt = nil }
        if case .holding(let heldID) = state, heldID == layerID {
            state = .base
            lastTapAt = nil
            return
        }
        if let lastTapAt, time - lastTapAt <= doubleTapWindow {
            state = .locked(layerID)
            self.lastTapAt = nil
        } else {
            state = .oneShot(layerID)
            lastTapAt = time
        }
    }

    mutating func layerForAction(at time: TimeInterval) -> String? {
        if let id = pressedLayerID, let started = pressStartedAt, time - started >= 0 {
            state = .holding(id)
        }
        switch state {
        case .base: return nil
        case .holding(let id), .locked(let id): return id
        case .oneShot(let id):
            state = .base
            lastTapAt = nil
            return id
        }
    }

    mutating func reset() {
        state = .base
        pressedLayerID = nil
        pressStartedAt = nil
        lastTapAt = nil
    }

    var announcement: String? {
        switch state {
        case .base: "Base layer"
        case .holding(let id): "\(id.capitalized) layer"
        case .oneShot(let id): "\(id.capitalized) layer one-shot active"
        case .locked(let id): "\(id.capitalized) layer locked"
        }
    }
}

enum QuickNavigationCategory: String, CaseIterable, Codable, Sendable {
    case headings = "Headings"
    case links = "Links"
    case formControls = "Form controls"
    case editFields = "Edit fields"
    case buttons = "Buttons"
    case landmarks = "Landmarks"
    case tables = "Tables"
    case lists = "Lists"

    var key: WindowsKeyboardKey {
        switch self {
        case .headings: .h; case .links: .k; case .formControls: .f
        case .editFields: .e; case .buttons: .b; case .landmarks: .d
        case .tables: .t; case .lists: .l
        }
    }
}

struct QuickNavigationEngine: Sendable {
    private(set) var isActive = false
    private(set) var category = QuickNavigationCategory.headings

    mutating func toggle() -> String {
        isActive.toggle()
        return isActive ? "Quick Navigation. \(category.rawValue)." : "Quick Navigation off."
    }

    mutating func exit() -> String? {
        guard isActive else { return nil }
        isActive = false
        return "Quick Navigation off."
    }

    mutating func nextCategory() -> String {
        let categories = QuickNavigationCategory.allCases
        let index = (categories.firstIndex(of: category)! + 1) % categories.count
        category = categories[index]
        return category.rawValue
    }

    mutating func previousCategory() -> String {
        let categories = QuickNavigationCategory.allCases
        let index = (categories.firstIndex(of: category)! - 1 + categories.count) % categories.count
        category = categories[index]
        return category.rawValue
    }
}

enum ControllerTextCharacterMapper {
    static func action(for character: Character) -> KeyboardAction? {
        let value = String(character)
        guard value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 65...90:
            let lower = String(UnicodeScalar(scalar.value + 32)!)
            return .init(key: WindowsKeyboardKey(rawValue: lower)!, modifiers: [.shift])
        case 97...122:
            return .init(key: WindowsKeyboardKey(rawValue: value)!)
        case 48...57:
            return .init(key: WindowsKeyboardKey(rawValue: "digit\(value)")!)
        case 32: return .init(key: .space)
        case 10, 13: return .init(key: .enter)
        case 45: return .init(key: .minus)
        case 61: return .init(key: .equal)
        case 44: return .init(key: .comma)
        case 46: return .init(key: .period)
        case 47: return .init(key: .slash)
        case 59: return .init(key: .semicolon)
        case 39: return .init(key: .quote)
        default: return nil
        }
    }
}
