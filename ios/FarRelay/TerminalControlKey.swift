import Foundation

/// The terminal-representable base keys available to a configured Control Key.
public enum TerminalControlBaseKey: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case returnKey
    case escape
    case tab
    case backspace
    case upArrow
    case downArrow
    case leftArrow
    case rightArrow
    case letter

    public var label: String {
        switch self {
        case .returnKey: "Return"
        case .escape: "Escape"
        case .tab: "Tab"
        case .backspace: "Backspace"
        case .upArrow: "Up Arrow"
        case .downArrow: "Down Arrow"
        case .leftArrow: "Left Arrow"
        case .rightArrow: "Right Arrow"
        case .letter: "Letter"
        }
    }
}

/// Modifiers with deterministic byte encodings in the current terminal path.
public enum TerminalControlModifier: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case control
    case alt
    case shift

    public var label: String {
        switch self {
        case .control: "Control"
        case .alt: "Alt"
        case .shift: "Shift"
        }
    }
}

/// A semantic terminal key chord. The letter is stored independently so the
/// configuration never persists opaque terminal bytes.
public struct TerminalControlChord: Codable, Equatable, Hashable, Sendable {
    public var baseKey: TerminalControlBaseKey
    public var letter: String?
    public var modifiers: Set<TerminalControlModifier>

    public init(
        baseKey: TerminalControlBaseKey,
        letter: String? = nil,
        modifiers: Set<TerminalControlModifier> = []
    ) {
        self.baseKey = baseKey
        self.letter = letter?.lowercased()
        self.modifiers = modifiers
    }

    public static let returnKey = TerminalControlChord(baseKey: .returnKey)
    public static let escape = TerminalControlChord(baseKey: .escape)
    public static let tab = TerminalControlChord(baseKey: .tab)
    public static let backspace = TerminalControlChord(baseKey: .backspace)
    public static let upArrow = TerminalControlChord(baseKey: .upArrow)
    public static let downArrow = TerminalControlChord(baseKey: .downArrow)
    public static let leftArrow = TerminalControlChord(baseKey: .leftArrow)
    public static let rightArrow = TerminalControlChord(baseKey: .rightArrow)

    public var suggestedName: String {
        let keyName: String
        switch baseKey {
        case .letter:
            keyName = letter?.uppercased() ?? "Letter"
        default:
            keyName = baseKey.label
        }
        let modifierNames = [
            TerminalControlModifier.control,
            .alt,
            .shift,
        ].compactMap { modifiers.contains($0) ? $0.label : nil }
        return (modifierNames + [keyName]).joined(separator: "-")
    }

    private enum CodingKeys: String, CodingKey {
        case baseKey
        case letter
        case modifiers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            baseKey: try container.decode(TerminalControlBaseKey.self, forKey: .baseKey),
            letter: try container.decodeIfPresent(String.self, forKey: .letter),
            modifiers: try container.decode(Set<TerminalControlModifier>.self, forKey: .modifiers)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseKey, forKey: .baseKey)
        try container.encodeIfPresent(letter, forKey: .letter)
        try container.encode(modifiers.sorted { $0.rawValue < $1.rawValue }, forKey: .modifiers)
    }
}

public enum TerminalControlChordError: Error, Equatable, Sendable {
    case missingLetter
    case unsupportedLetter(String)
    case unsupportedModifiers
    case ambiguousControlShift
    case unsupportedControlAlt

    public var explanation: String {
        switch self {
        case .missingLetter:
            "Choose a letter for this terminal chord."
        case .unsupportedLetter:
            "Terminal Control Keys support ASCII letters A through Z only."
        case .unsupportedModifiers:
            "This key does not support the selected modifiers in a standard terminal session."
        case .ambiguousControlShift:
            "Control-Shift-letter is not available because this terminal path cannot distinguish it from Control-letter."
        case .unsupportedControlAlt:
            "Control-Alt-letter is not available through the current terminal input path."
        }
    }
}

/// Converts semantic terminal chords into their exact PTY byte sequence.
public enum TerminalControlChordEncoder {
    public static func encode(_ chord: TerminalControlChord) -> Result<Data, TerminalControlChordError> {
        switch chord.baseKey {
        case .returnKey:
            return simpleKey(chord, bytes: [0x0D])
        case .escape:
            return simpleKey(chord, bytes: [0x1B])
        case .tab:
            if chord.modifiers.isEmpty {
                return .success(Data([0x09]))
            }
            if chord.modifiers == [.shift] {
                return .success(Data("\u{1B}[Z".utf8))
            }
            return .failure(.unsupportedModifiers)
        case .backspace:
            return simpleKey(chord, bytes: [0x7F])
        case .upArrow:
            return simpleKey(chord, bytes: Array("\u{1B}[A".utf8))
        case .downArrow:
            return simpleKey(chord, bytes: Array("\u{1B}[B".utf8))
        case .leftArrow:
            return simpleKey(chord, bytes: Array("\u{1B}[D".utf8))
        case .rightArrow:
            return simpleKey(chord, bytes: Array("\u{1B}[C".utf8))
        case .letter:
            return letter(chord)
        }
    }

    private static func simpleKey(_ chord: TerminalControlChord, bytes: [UInt8]) -> Result<Data, TerminalControlChordError> {
        guard chord.modifiers.isEmpty, chord.letter == nil else { return .failure(.unsupportedModifiers) }
        return .success(Data(bytes))
    }

    private static func letter(_ chord: TerminalControlChord) -> Result<Data, TerminalControlChordError> {
        guard let letter = chord.letter else { return .failure(.missingLetter) }
        guard letter.count == 1,
              let scalar = letter.unicodeScalars.first,
              scalar.value >= 97,
              scalar.value <= 122 else {
            return .failure(.unsupportedLetter(letter))
        }

        if chord.modifiers.contains(.control) {
            if chord.modifiers.contains(.shift) {
                return .failure(.ambiguousControlShift)
            }
            if chord.modifiers.contains(.alt) {
                return .failure(.unsupportedControlAlt)
            }
            return .success(Data([UInt8(scalar.value - 96)]))
        }

        let character = chord.modifiers.contains(.shift)
            ? letter.uppercased()
            : letter
        if chord.modifiers.contains(.alt) {
            var bytes = Data([0x1B])
            bytes.append(contentsOf: character.utf8)
            return .success(bytes)
        }
        return .success(Data(character.utf8))
    }
}

public enum TerminalControlKeyValidationError: Error, Equatable, Sendable {
    case emptyName
    case invalidChord(TerminalControlChordError)
    case duplicateChord

    public var explanation: String {
        switch self {
        case .emptyName:
            "Enter a name for this Control Key."
        case .invalidChord(let error):
            error.explanation
        case .duplicateChord:
            "Another Control Key already uses this exact chord."
        }
    }
}

/// A user-configured terminal control with a stable action ID independent of
/// its label and collection position.
public struct TerminalControlKey: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var chord: TerminalControlChord

    public init(id: String = "terminal.custom.\(UUID().uuidString.lowercased())", name: String? = nil, chord: TerminalControlChord) {
        self.id = id
        self.name = name ?? chord.suggestedName
        self.chord = chord
    }

    public static let defaultControls: [TerminalControlKey] = [
        TerminalControlKey(id: "terminal.return", chord: .returnKey),
        TerminalControlKey(id: "terminal.escape", chord: .escape),
        TerminalControlKey(id: "terminal.tab", chord: .tab),
        TerminalControlKey(id: "terminal.shift-tab", chord: TerminalControlChord(baseKey: .tab, modifiers: [.shift])),
        TerminalControlKey(id: "terminal.backspace", chord: .backspace),
        TerminalControlKey(id: "terminal.up-arrow", chord: .upArrow),
        TerminalControlKey(id: "terminal.down-arrow", chord: .downArrow),
        TerminalControlKey(id: "terminal.left-arrow", chord: .leftArrow),
        TerminalControlKey(id: "terminal.right-arrow", chord: .rightArrow),
        TerminalControlKey(id: "terminal.interrupt", chord: TerminalControlChord(baseKey: .letter, letter: "c", modifiers: [.control])),
        TerminalControlKey(id: "terminal.eof", chord: TerminalControlChord(baseKey: .letter, letter: "d", modifiers: [.control])),
        TerminalControlKey(id: "terminal.clear", chord: TerminalControlChord(baseKey: .letter, letter: "l", modifiers: [.control])),
        TerminalControlKey(id: "terminal.history-search", chord: TerminalControlChord(baseKey: .letter, letter: "r", modifiers: [.control])),
        TerminalControlKey(id: "terminal.suspend", chord: TerminalControlChord(baseKey: .letter, letter: "z", modifiers: [.control])),
    ]

    public static func defaultControl(id: String) -> TerminalControlKey? {
        defaultControls.first(where: { $0.id == id })
    }

    public func validationError(among controls: [TerminalControlKey]) -> TerminalControlKeyValidationError? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .emptyName }
        if case let .failure(error) = TerminalControlChordEncoder.encode(chord) {
            return .invalidChord(error)
        }
        guard !controls.contains(where: { $0.id != id && $0.chord == chord }) else {
            return .duplicateChord
        }
        return nil
    }
}
