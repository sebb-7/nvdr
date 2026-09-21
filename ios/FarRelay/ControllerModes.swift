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

    /// The layer whose physical controller button is still down. This remains
    /// nil for one-shot and locked layers, which lets the adapter scope a
    /// held modifier specifically to a real layer-button hold.
    var physicallyHeldLayerID: String? { pressedLayerID }

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
    case quickBar = "Quick Bar"
    case profiles = "Profiles"
    case headings = "Headings"
    case links = "Links"
    case formControls = "Form controls"
    case editFields = "Edit fields"
    case buttons = "Buttons"
    case landmarks = "Landmarks"
    case tables = "Tables"
    case lists = "Lists"

    var key: WindowsKeyboardKey? {
        switch self {
        case .quickBar, .profiles: nil
        case .headings: .h
        case .links: .k
        case .formControls: .f
        case .editFields: .e
        case .buttons: .b
        case .landmarks: .d
        case .tables: .t
        case .lists: .l
        }
    }
}

struct QuickNavigationCategoryChange: Equatable, Sendable {
    let announcement: String
    let wrapped: Bool
}

struct QuickNavigationEngine: Sendable {
    private(set) var isActive = false
    private(set) var category = QuickNavigationCategory.quickBar
    private(set) var quickBarIndex = 0
    private(set) var profileIndex = 0

    mutating func toggle() -> String {
        isActive.toggle()
        return isActive ? "Quick Navigation. \(category.rawValue)." : "Quick Navigation off."
    }

    mutating func exit() -> String? {
        guard isActive else { return nil }
        isActive = false
        return "Quick Navigation off."
    }

    mutating func nextCategoryChange() -> QuickNavigationCategoryChange {
        let categories = QuickNavigationCategory.allCases
        let previous = category
        let index = (categories.firstIndex(of: category)! + 1) % categories.count
        category = categories[index]
        return .init(
            announcement: category.rawValue,
            wrapped: previous == categories.last && category == categories.first
        )
    }

    mutating func previousCategoryChange() -> QuickNavigationCategoryChange {
        let categories = QuickNavigationCategory.allCases
        let previous = category
        let index = (categories.firstIndex(of: category)! - 1 + categories.count) % categories.count
        category = categories[index]
        return .init(
            announcement: category.rawValue,
            wrapped: previous == categories.first && category == categories.last
        )
    }

    mutating func nextCategory() -> String { nextCategoryChange().announcement }
    mutating func previousCategory() -> String { previousCategoryChange().announcement }

    func selectedQuickBarEntry(in entries: [QuickBarEntry]) -> QuickBarEntry? {
        guard !entries.isEmpty else { return nil }
        return entries[min(quickBarIndex, entries.count - 1)]
    }

    mutating func nextQuickBarAction(in entries: [QuickBarEntry]) -> String {
        guard !entries.isEmpty else {
            quickBarIndex = 0
            return "Quick Bar empty"
        }
        quickBarIndex = (min(quickBarIndex, entries.count - 1) + 1) % entries.count
        return selectedQuickBarEntry(in: entries)?.label ?? "Quick Bar empty"
    }

    mutating func previousQuickBarAction(in entries: [QuickBarEntry]) -> String {
        guard !entries.isEmpty else {
            quickBarIndex = 0
            return "Quick Bar empty"
        }
        let current = min(quickBarIndex, entries.count - 1)
        quickBarIndex = (current - 1 + entries.count) % entries.count
        return selectedQuickBarEntry(in: entries)?.label ?? "Quick Bar empty"
    }

    mutating func synchronizeProfileSelection(
        profiles: [ControllerProfile],
        activeProfileID: UUID
    ) {
        guard !profiles.isEmpty else {
            profileIndex = 0
            return
        }
        profileIndex = profiles.firstIndex(where: { $0.id == activeProfileID }) ?? 0
    }

    func selectedProfile(in profiles: [ControllerProfile]) -> ControllerProfile? {
        guard !profiles.isEmpty else { return nil }
        return profiles[min(profileIndex, profiles.count - 1)]
    }

    mutating func nextProfile(in profiles: [ControllerProfile]) -> String {
        guard !profiles.isEmpty else {
            profileIndex = 0
            return "No profiles"
        }
        profileIndex = (min(profileIndex, profiles.count - 1) + 1) % profiles.count
        return selectedProfile(in: profiles)?.name ?? "No profiles"
    }

    mutating func previousProfile(in profiles: [ControllerProfile]) -> String {
        guard !profiles.isEmpty else {
            profileIndex = 0
            return "No profiles"
        }
        let current = min(profileIndex, profiles.count - 1)
        profileIndex = (current - 1 + profiles.count) % profiles.count
        return selectedProfile(in: profiles)?.name ?? "No profiles"
    }

    func currentSectionAnnouncement(
        quickBar: [QuickBarEntry],
        profiles: [ControllerProfile]
    ) -> String {
        switch category {
        case .quickBar:
            return "Quick Bar. \(selectedQuickBarEntry(in: quickBar)?.label ?? "Empty")"
        case .profiles:
            return "Profiles. \(selectedProfile(in: profiles)?.name ?? "None")"
        default:
            return category.rawValue
        }
    }
}

struct ControllerDeviceStatus: Equatable, Sendable {
    var name: String
    var batteryPercent: Int?
    var batteryStateLabel: String?
    var supportsHaptics: Bool
    var supportsTouchpad: Bool

    var compactLabel: String {
        var parts = [name]
        if let batteryPercent {
            parts.append("Battery \(batteryPercent) percent")
        } else {
            parts.append("Battery unavailable")
        }
        if let batteryStateLabel { parts.append(batteryStateLabel) }
        if supportsHaptics { parts.append("Haptics") }
        if supportsTouchpad { parts.append("Touchpad") }
        return parts.joined(separator: " · ")
    }
}

struct TouchpadRotorGesture: Sendable {
    private(set) var startX: Float?
    private(set) var consumed = false
    let threshold: Float

    init(threshold: Float = 0.35) {
        self.threshold = threshold
    }

    mutating func begin(x: Float) {
        startX = x
        consumed = false
    }

    mutating func move(x: Float) -> Int? {
        guard let startX, !consumed else { return nil }
        let delta = x - startX
        guard abs(delta) >= threshold else { return nil }
        consumed = true
        return delta > 0 ? 1 : -1
    }

    mutating func end() {
        startX = nil
        consumed = false
    }
}

enum ControllerTextCharacterMapper {
    static func action(for character: Character) -> KeyboardAction? {
        let value = String(character)
        guard value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first else { return nil }

        func shifted(_ key: WindowsKeyboardKey) -> KeyboardAction {
            .init(key: key, modifiers: [.shift])
        }

        switch scalar.value {
        case 65...90:
            let lower = String(UnicodeScalar(scalar.value + 32)!)
            return shifted(WindowsKeyboardKey(rawValue: lower)!)
        case 97...122:
            return .init(key: WindowsKeyboardKey(rawValue: value)!)
        case 48...57:
            return .init(key: WindowsKeyboardKey(rawValue: "digit\(value)")!)
        case 9: return .init(key: .tab)
        case 10, 13: return .init(key: .enter)
        case 32: return .init(key: .space)
        case 33: return shifted(.digit1)
        case 34: return shifted(.quote)
        case 35: return shifted(.digit3)
        case 36: return shifted(.digit4)
        case 37: return shifted(.digit5)
        case 38: return shifted(.digit7)
        case 39: return .init(key: .quote)
        case 40: return shifted(.digit9)
        case 41: return shifted(.digit0)
        case 42: return shifted(.digit8)
        case 43: return shifted(.equal)
        case 44: return .init(key: .comma)
        case 45: return .init(key: .minus)
        case 46: return .init(key: .period)
        case 47: return .init(key: .slash)
        case 58: return shifted(.semicolon)
        case 59: return .init(key: .semicolon)
        case 60: return shifted(.comma)
        case 61: return .init(key: .equal)
        case 62: return shifted(.period)
        case 63: return shifted(.slash)
        case 64: return shifted(.digit2)
        case 91: return .init(key: .leftBracket)
        case 92: return .init(key: .backslash)
        case 93: return .init(key: .rightBracket)
        case 94: return shifted(.digit6)
        case 95: return shifted(.minus)
        case 96: return .init(key: .grave)
        case 123: return shifted(.leftBracket)
        case 124: return shifted(.backslash)
        case 125: return shifted(.rightBracket)
        case 126: return shifted(.grave)
        default: return nil
        }
    }
}
