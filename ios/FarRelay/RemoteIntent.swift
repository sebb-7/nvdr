import Foundation

/// Input-source-independent commands for an explicitly selected remote target.
enum RemoteIntent: Equatable, Sendable {
    case nextItem
    case previousItem
    case activate
    case cancel

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
    case macRemote(MacRemoteAction)

    var requiredCapability: RemoteCapability {
        switch self {
        case .nextItem, .previousItem, .activate, .cancel:
            .genericNavigation
        case .nextApplication, .previousApplication, .closeWindow, .showDesktop, .openStart:
            .applicationNavigation
        case .reviewPrevious, .reviewNext, .returnToLive:
            .terminalReview
        case .terminalInterrupt, .terminalEOF:
            .terminalControl
        case .sendKey:
            .rawKeyInput
        case .sendChord:
            .rawChordInput
        case .macRemote:
            .macRemoteControl
        }
    }
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
    }

    static let tab = RemoteKey(storage: .named(.tab))
    static let returnKey = RemoteKey(storage: .named(.returnKey))
    static let escape = RemoteKey(storage: .named(.escape))
    static let backspace = RemoteKey(storage: .named(.backspace))
    static let leftArrow = RemoteKey(storage: .named(.leftArrow))
    static let rightArrow = RemoteKey(storage: .named(.rightArrow))
    static let upArrow = RemoteKey(storage: .named(.upArrow))
    static let downArrow = RemoteKey(storage: .named(.downArrow))

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
