import Foundation

/// Input-source-independent commands for an explicitly selected remote target.
enum RemoteIntent: Equatable, Sendable {
    /// Legacy focus traversal. On NVDA this deliberately remains Tab/Shift-Tab
    /// so existing controller behavior is not silently redefined.
    case nextItem
    case previousItem
    case activate
    case cancel

    /// Screen-reader semantic navigation. These are deliberately distinct
    /// from focus traversal above: targets choose their own safe translation.
    case accessibilityNext
    case accessibilityPrevious
    case accessibilityActivate
    case recovery(RecoveryAction)

    case nextApplication
    case previousApplication
    case closeWindow
    case showDesktop
    case openStart

    case reviewPrevious
    case reviewNext
    case returnToLive
    case terminalInterrupt
    case terminalEOF

    case sendKey(RemoteKey)
    case sendChord(RemoteChord)
    /// Stateful raw input used by controller adapters. A matching release is
    /// required so a remote modifier or key cannot remain held after a local
    /// controller lifecycle change.
    case sendKeyTransition(RemoteKey, pressed: Bool)
    case sendChordTransition(RemoteChord, pressed: Bool)
    /// A repeat is an additional down transition for an already held action.
    /// It deliberately never changes held-key ownership.
    case repeatKey(RemoteKey)
    case repeatChord(RemoteChord)
    /// Transitional compatibility for the original Mac-only foundation.
    /// Input sources must use the platform-neutral accessibility and
    /// application intents instead. This remains until old callers can be
    /// removed without bypassing MacRemoteSession's lease protections.
    case macRemote(MacRemoteAction)

    var requiredCapability: RemoteCapability {
        switch self {
        case .nextItem, .previousItem, .activate, .cancel:
            .genericNavigation
        case .accessibilityNext, .accessibilityPrevious, .accessibilityActivate:
            .accessibilityNavigation
        case .recovery:
            .hostRecovery
        case .nextApplication:
            .applicationSwitching
        case .previousApplication, .closeWindow, .showDesktop, .openStart:
            .applicationNavigation
        case .reviewPrevious, .reviewNext, .returnToLive:
            .terminalReview
        case .terminalInterrupt, .terminalEOF:
            .terminalControl
        case .sendKey, .sendKeyTransition, .repeatKey:
            .rawKeyInput
        case .sendChord, .sendChordTransition, .repeatChord:
            .rawChordInput
        case .macRemote:
            .macRemoteControl
        }
    }
}

/// Platform-neutral recovery commands. A host-scoped target chooses the
/// implementation; input producers never name NVDA, VoiceOver, or Orca.
enum RecoveryAction: Equatable, Sendable {
    case restartAccessibility
}

/// The semantic Mac actions already exercised by the foundation's diagnostic
/// controls. They intentionally describe user intent rather than HID chords.
enum MacRemoteAction: Equatable, Sendable {
    case nextItem
    case previousItem
    case activate
    case nextApplication
}

enum RemoteModifier: Hashable, Sendable {
    case shift
    case control
    case alt
    case commandOrWindows
    case capsLock
}

enum RemoteNamedKey: Hashable, Sendable {
    case tab
    case returnKey
    case escape
    case backspace
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
}

/// A deliberately limited, platform-neutral raw key fallback.
struct RemoteKey: Hashable, Sendable {
    private enum Storage: Hashable, Sendable {
        case named(RemoteNamedKey)
        case function(Int)
        case letter(Character)
        case windowsVirtualKey(UInt16)
    }

    static let tab = RemoteKey(storage: .named(.tab))
    static let returnKey = RemoteKey(storage: .named(.returnKey))
    static let escape = RemoteKey(storage: .named(.escape))
    static let backspace = RemoteKey(storage: .named(.backspace))
    static let leftArrow = RemoteKey(storage: .named(.leftArrow))
    static let rightArrow = RemoteKey(storage: .named(.rightArrow))
    static let upArrow = RemoteKey(storage: .named(.upArrow))
    static let downArrow = RemoteKey(storage: .named(.downArrow))
    static func windowsVirtualKey(_ value: UInt16) -> RemoteKey { RemoteKey(storage: .windowsVirtualKey(value)) }

    private let storage: Storage

    private init(storage: Storage) {
        self.storage = storage
    }

    /// Returns nil outside the standard F1 through F24 range.
    static func function(_ number: Int) -> RemoteKey? {
        guard (1...24).contains(number) else { return nil }
        return RemoteKey(storage: .function(number))
    }

    /// Accepts one ASCII letter. The stored value remains platform-neutral.
    static func letter(_ character: Character) -> RemoteKey? {
        let scalars = String(character).unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return nil }
        guard (65...90).contains(scalar.value) || (97...122).contains(scalar.value) else {
            return nil
        }
        return RemoteKey(storage: .letter(character))
    }

    var functionNumber: Int? {
        guard case .function(let number) = storage else { return nil }
        return number
    }

    var namedKey: RemoteNamedKey? {
        guard case .named(let key) = storage else { return nil }
        return key
    }

    var letterCharacter: Character? {
        guard case .letter(let character) = storage else { return nil }
        return character
    }

    var windowsVirtualKey: UInt16? {
        guard case .windowsVirtualKey(let value) = storage else { return nil }
        return value
    }

}

struct RemoteChord: Equatable, Sendable {
    let modifiers: Set<RemoteModifier>
    let key: RemoteKey

    init(modifiers: Set<RemoteModifier>, key: RemoteKey) {
        self.modifiers = modifiers
        self.key = key
    }
}

enum RemoteCapability: Hashable, Sendable {
    case genericNavigation
    case accessibilityNavigation
    case hostRecovery
    case applicationSwitching
    case applicationNavigation
    case terminalReview
    case terminalControl
    case rawKeyInput
    case rawChordInput
    case macRemoteControl
}

struct RemoteTargetID: Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

enum RemoteIntentResult: Equatable, Sendable {
    case performed
    case unsupported
    case unavailable(String)
    case failed(String)
}
