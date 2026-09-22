import Foundation

/// A deliberately small, deterministic grammar for one-shot keyboard escape
/// commands. It is not a macro language: there are no delays, loops,
/// variables, conditions, saved scripts, or command-specific semantics.
///
/// Syntax:
/// - "+" means press keys together.
/// - "," means perform the next step.
/// - A comma-delimited token that is not a known key is literal text.
///
/// Examples:
///   ctrl+v
///   win+r,powershell,enter
///   ctrl+l,github.com,enter
struct QuickCommand: Equatable, Sendable {
    let steps: [QuickCommandStep]

    var spokenDescription: String {
        steps.map(\.spokenDescription).joined(separator: ". Then ")
    }
}

enum QuickCommandStep: Equatable, Sendable {
    case chord(QuickCommandChord)
    case text(String)

    var spokenDescription: String {
        switch self {
        case .chord(let chord):
            chord.spokenDescription
        case .text(let text):
            "Type \(text)"
        }
    }
}

struct QuickCommandChord: Equatable, Sendable {
    let keys: [QuickCommandChordKey]

    var spokenDescription: String {
        keys.map(\.spokenName).joined(separator: " plus ")
    }
}

enum QuickCommandChordKey: Hashable, Sendable {
    case modifier(QuickCommandModifier)
    case key(QuickCommandKey)

    var spokenName: String {
        switch self {
        case .modifier(let modifier): modifier.spokenName
        case .key(let key): key.spokenName
        }
    }

    var isModifier: Bool {
        if case .modifier = self { return true }
        return false
    }
}

enum QuickCommandModifier: String, Hashable, Sendable {
    case control
    case shift
    case alt
    case windows
    case command
    case option
    case nvda

    var spokenName: String {
        switch self {
        case .control: "Control"
        case .shift: "Shift"
        case .alt: "Alt"
        case .windows: "Windows"
        case .command: "Command"
        case .option: "Option"
        case .nvda: "NVDA"
        }
    }
}

enum QuickCommandKey: Hashable, Sendable {
    case named(QuickCommandNamedKey)
    case function(Int)
    case character(Character)

    var spokenName: String {
        switch self {
        case .named(let key): key.spokenName
        case .function(let number): "F\(number)"
        case .character(let character): String(character).uppercased()
        }
    }
}

enum QuickCommandNamedKey: String, Hashable, Sendable {
    case tab
    case enter
    case escape
    case space
    case backspace
    case delete
    case insert
    case home
    case end
    case pageUp
    case pageDown
    case left
    case right
    case up
    case down
    case capsLock
    case pause
    case printScreen
    case scrollLock
    case numLock
    case contextMenu
    case comma
    case period
    case slash
    case backslash
    case semicolon
    case quote
    case grave
    case minus
    case equal
    case leftBracket
    case rightBracket

    var spokenName: String {
        switch self {
        case .tab: "Tab"
        case .enter: "Enter"
        case .escape: "Escape"
        case .space: "Space"
        case .backspace: "Backspace"
        case .delete: "Delete"
        case .insert: "Insert"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .left: "Left Arrow"
        case .right: "Right Arrow"
        case .up: "Up Arrow"
        case .down: "Down Arrow"
        case .capsLock: "Caps Lock"
        case .pause: "Pause"
        case .printScreen: "Print Screen"
        case .scrollLock: "Scroll Lock"
        case .numLock: "Num Lock"
        case .contextMenu: "Context Menu"
        case .comma: "Comma"
        case .period: "Period"
        case .slash: "Slash"
        case .backslash: "Backslash"
        case .semicolon: "Semicolon"
        case .quote: "Quote"
        case .grave: "Grave"
        case .minus: "Minus"
        case .equal: "Equal"
        case .leftBracket: "Left Bracket"
        case .rightBracket: "Right Bracket"
        }
    }
}

enum QuickCommandParseError: Error, Equatable, Sendable {
    case emptyInput
    case tooManySteps(maximum: Int)
    case emptyStep(position: Int)
    case tooManyChordKeys(position: Int, maximum: Int)
    case emptyChordKey(position: Int)
    case unknownChordKey(String, position: Int)
    case duplicateChordKey(String, position: Int)
    case modifierOnlyChord(position: Int)
    case literalTextTooLong(position: Int, maximum: Int)

    var message: String {
        switch self {
        case .emptyInput:
            "Enter a quick command."
        case .tooManySteps(let maximum):
            "Quick Command supports at most \(maximum) steps."
        case .emptyStep(let position):
            "Step \(position) is empty."
        case .tooManyChordKeys(let position, let maximum):
            "Step \(position) has too many simultaneous keys. The maximum is \(maximum)."
        case .emptyChordKey(let position):
            "Step \(position) has a missing key around plus."
        case .unknownChordKey(let token, let position):
            "Step \(position) contains an unknown key: \(token)."
        case .duplicateChordKey(let token, let position):
            "Step \(position) repeats the same key: \(token)."
        case .modifierOnlyChord(let position):
            "Step \(position) needs at least one non-modifier key."
        case .literalTextTooLong(let position, let maximum):
            "Step \(position) has too much literal text. The maximum is \(maximum) characters."
        }
    }
}

enum QuickCommandExecutionPolicy {
    /// UI-changing grammar steps such as Win+R need a small, bounded settle
    /// boundary before the next step starts typing. Literal text itself is
    /// still emitted without per-character delay.
    static let interStepDelayNanoseconds: UInt64 = 180_000_000
}

struct QuickCommandParser: Sendable {
    static let maximumSteps = 5
    static let maximumChordKeys = 4
    static let maximumLiteralCharacters = 256

    static func parse(_ input: String) throws -> QuickCommand {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuickCommandParseError.emptyInput
        }

        let rawSteps = input.split(separator: ",", omittingEmptySubsequences: false)
        guard rawSteps.count <= maximumSteps else {
            throw QuickCommandParseError.tooManySteps(maximum: maximumSteps)
        }

        var steps: [QuickCommandStep] = []
        steps.reserveCapacity(rawSteps.count)

        for (offset, rawStep) in rawSteps.enumerated() {
            let position = offset + 1
            let token = String(rawStep).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw QuickCommandParseError.emptyStep(position: position)
            }

            if token.contains("+") {
                steps.append(.chord(try parseChord(token, position: position)))
                continue
            }

            if let key = resolveChordKey(token) {
                let chord = try validateChord([key], originalTokens: [token], position: position)
                steps.append(.chord(chord))
                continue
            }

            guard token.count <= maximumLiteralCharacters else {
                throw QuickCommandParseError.literalTextTooLong(
                    position: position,
                    maximum: maximumLiteralCharacters
                )
            }
            steps.append(.text(token))
        }

        return QuickCommand(steps: steps)
    }

    private static func parseChord(_ token: String, position: Int) throws -> QuickCommandChord {
        let rawKeys = token.split(separator: "+", omittingEmptySubsequences: false)
        guard rawKeys.count <= maximumChordKeys else {
            throw QuickCommandParseError.tooManyChordKeys(
                position: position,
                maximum: maximumChordKeys
            )
        }

        var resolved: [QuickCommandChordKey] = []
        var originals: [String] = []
        resolved.reserveCapacity(rawKeys.count)
        originals.reserveCapacity(rawKeys.count)

        for rawKey in rawKeys {
            let keyToken = String(rawKey).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyToken.isEmpty else {
                throw QuickCommandParseError.emptyChordKey(position: position)
            }
            guard let key = resolveChordKey(keyToken) else {
                throw QuickCommandParseError.unknownChordKey(keyToken, position: position)
            }
            resolved.append(key)
            originals.append(keyToken)
        }

        return try validateChord(resolved, originalTokens: originals, position: position)
    }

    private static func validateChord(
        _ keys: [QuickCommandChordKey],
        originalTokens: [String],
        position: Int
    ) throws -> QuickCommandChord {
        var seen = Set<QuickCommandChordKey>()
        for (index, key) in keys.enumerated() where !seen.insert(key).inserted {
            throw QuickCommandParseError.duplicateChordKey(
                originalTokens[index],
                position: position
            )
        }
        guard keys.contains(where: { !$0.isModifier }) else {
            throw QuickCommandParseError.modifierOnlyChord(position: position)
        }
        return QuickCommandChord(keys: keys)
    }

    private static func resolveChordKey(_ token: String) -> QuickCommandChordKey? {
        let normalized = normalize(token)

        if let modifier = modifierAliases[normalized] {
            return .modifier(modifier)
        }
        if let named = namedKeyAliases[normalized] {
            return .key(.named(named))
        }
        if normalized.count == 1,
           let character = normalized.first,
           character.isASCII,
           (character.isLetter || character.isNumber) {
            return .key(.character(character))
        }
        if normalized.first == "f",
           let number = Int(normalized.dropFirst()),
           (1...24).contains(number) {
            return .key(.function(number))
        }
        return nil
    }

    private static func normalize(_ token: String) -> String {
        token
            .lowercased()
            .filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }

    private static let modifierAliases: [String: QuickCommandModifier] = [
        "ctrl": .control,
        "control": .control,
        "shift": .shift,
        "alt": .alt,
        "win": .windows,
        "windows": .windows,
        "cmd": .command,
        "command": .command,
        "opt": .option,
        "option": .option,
        "nvda": .nvda,
    ]

    private static let namedKeyAliases: [String: QuickCommandNamedKey] = [
        "tab": .tab,
        "enter": .enter,
        "return": .enter,
        "esc": .escape,
        "escape": .escape,
        "space": .space,
        "backspace": .backspace,
        "bs": .backspace,
        "del": .delete,
        "delete": .delete,
        "supr": .delete,
        "ins": .insert,
        "insert": .insert,
        "home": .home,
        "end": .end,
        "pgup": .pageUp,
        "pageup": .pageUp,
        "pgdn": .pageDown,
        "pagedown": .pageDown,
        "left": .left,
        "leftarrow": .left,
        "right": .right,
        "rightarrow": .right,
        "up": .up,
        "uparrow": .up,
        "down": .down,
        "downarrow": .down,
        "capslock": .capsLock,
        "pause": .pause,
        "prtsc": .printScreen,
        "printscreen": .printScreen,
        "scrolllock": .scrollLock,
        "numlock": .numLock,
        "menu": .contextMenu,
        "apps": .contextMenu,
        "contextmenu": .contextMenu,
        "comma": .comma,
        "period": .period,
        "dot": .period,
        "slash": .slash,
        "backslash": .backslash,
        "semicolon": .semicolon,
        "quote": .quote,
        "grave": .grave,
        "backtick": .grave,
        "minus": .minus,
        "equal": .equal,
        "leftbracket": .leftBracket,
        "rightbracket": .rightBracket,
    ]
}

extension QuickCommandParseError: LocalizedError {
    var errorDescription: String? { message }
}
