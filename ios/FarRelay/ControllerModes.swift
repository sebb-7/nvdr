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
    private var lastTapAt: TimeInterval?
    private var suppressNextReleaseForLayerID: String?
    private let doubleTapWindow: TimeInterval

    init(doubleTapWindow: TimeInterval = 0.35) {
        self.doubleTapWindow = doubleTapWindow
    }

    /// The adapter calls this before resolving ordinary mappings. A layer
    /// control is therefore never shadowed by its active layer.
    mutating func press(layerID: String, at time: TimeInterval) -> LayerFeedback {
        if case .locked(let lockedID) = state, lockedID == layerID {
            state = .base
            lastTapAt = nil
            suppressNextReleaseForLayerID = layerID
            return .base
        }
        pressedLayerID = layerID
        return .activated(layerID)
    }

    mutating func release(layerID: String, at time: TimeInterval) -> LayerFeedback? {
        if suppressNextReleaseForLayerID == layerID {
            suppressNextReleaseForLayerID = nil
            return nil
        }
        guard pressedLayerID == layerID else { return nil }
        defer { pressedLayerID = nil }
        if case .holding(let heldID) = state, heldID == layerID {
            state = .base
            lastTapAt = nil
            return .base
        }
        if let lastTapAt, time - lastTapAt <= doubleTapWindow {
            state = .locked(layerID)
            self.lastTapAt = nil
            return .locked(layerID)
        }
        state = .oneShot(layerID)
        lastTapAt = time
        return .oneShot(layerID)
    }

    /// Resolves the active layer without consuming one-shot state. The caller
    /// consumes it only after a mapped non-control action has begun.
    mutating func layerForAction() -> String? {
        if let id = pressedLayerID {
            state = .holding(id)
        }
        switch state {
        case .base: return nil
        case .holding(let id), .oneShot(let id), .locked(let id): return id
        }
    }

    mutating func consumeOneShotAfterResolvedAction() -> LayerFeedback? {
        guard case .oneShot = state else { return nil }
        state = .base
        lastTapAt = nil
        return .base
    }

    mutating func reset() {
        state = .base
        pressedLayerID = nil
        lastTapAt = nil
        suppressNextReleaseForLayerID = nil
    }
}

enum LayerFeedback: Equatable, Sendable {
    case activated(String)
    case oneShot(String)
    case locked(String)
    case base

    var announcement: String {
        switch self {
        case .activated(let id): "\(id.capitalized) layer"
        case .oneShot(let id): "\(id.capitalized) layer one-shot"
        case .locked(let id): "\(id.capitalized) layer locked"
        case .base: "Base layer"
        }
    }
}

/// Text Mode v1 intentionally supports append-at-end and suffix deletion.
/// The ledger remembers which local entries own remote characters, so local
/// unsupported text can never delete unrelated remote text later.
struct TextModeMirrorSession: Sendable {
    private enum Status: Sendable { case mirrored, localOnly, remotelyDeleted }
    private var entries: [(character: Character, status: Status)] = []

    var text: String { String(entries.map(\.character)) }

    mutating func append(_ character: Character, mirrored: Bool) {
        entries.append((character, mirrored ? .mirrored : .localOnly))
    }

    mutating func deleteSuffix(count: Int) -> Int {
        guard count > 0 else { return 0 }
        let removed = entries.suffix(count)
        entries.removeLast(min(count, entries.count))
        return removed.filter { $0.status == .mirrored }.count
    }

    /// Returns true when the visible buffer's end was a known mirrored entry.
    /// A remote Backspace is still sent if no local correspondence exists.
    mutating func remoteBackspace() -> Bool {
        guard let index = entries.lastIndex(where: { $0.status == .mirrored }) else { return false }
        if index == entries.index(before: entries.endIndex) {
            entries.removeLast()
            return true
        }
        entries[index].status = .remotelyDeleted
        return false
    }

    mutating func reset() { entries.removeAll() }
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
