import Foundation
import XCTest
@testable import FarRelay

final class TerminalControlKeyTests: XCTestCase {
    func testDefaultControlsHaveUniqueStableIDsAndValidDistinctChords() {
        let controls = TerminalControlKey.defaultControls

        XCTAssertEqual(Set(controls.map(\.id)).count, controls.count)
        XCTAssertEqual(Set(controls.map(\.chord)).count, controls.count)
        XCTAssertTrue(controls.allSatisfy { $0.validationError(among: controls) == nil })
        XCTAssertTrue(controls.allSatisfy { successfulBytes(for: $0.chord) != nil })
    }

    func testExistingTerminalKeyBytesRemainExact() {
        XCTAssertEqual(successfulBytes(for: .returnKey), Data([0x0D]))
        XCTAssertEqual(successfulBytes(for: .escape), Data([0x1B]))
        XCTAssertEqual(successfulBytes(for: .tab), Data([0x09]))
        XCTAssertEqual(successfulBytes(for: .backspace), Data([0x7F]))
        XCTAssertEqual(successfulBytes(for: .upArrow), Data("\u{1B}[A".utf8))
        XCTAssertEqual(successfulBytes(for: .downArrow), Data("\u{1B}[B".utf8))
        XCTAssertEqual(successfulBytes(for: .leftArrow), Data("\u{1B}[D".utf8))
        XCTAssertEqual(successfulBytes(for: .rightArrow), Data("\u{1B}[C".utf8))
        XCTAssertEqual(successfulBytes(for: controlLetter("c")), Data([0x03]))
        XCTAssertEqual(successfulBytes(for: controlLetter("d")), Data([0x04]))
    }

    func testControlLettersAThroughZEncodeToASCIIControlBytes() {
        for (offset, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            XCTAssertEqual(
                successfulBytes(for: controlLetter(String(letter))),
                Data([UInt8(offset + 1)])
            )
        }
    }

    func testShiftTabAndAltLettersUseExactSupportedSequences() {
        XCTAssertEqual(
            successfulBytes(for: TerminalControlChord(baseKey: .tab, modifiers: [.shift])),
            Data("\u{1B}[Z".utf8)
        )
        XCTAssertEqual(
            successfulBytes(for: TerminalControlChord(baseKey: .letter, letter: "x", modifiers: [.alt])),
            Data("\u{1B}x".utf8)
        )
        XCTAssertEqual(
            successfulBytes(for: TerminalControlChord(baseKey: .letter, letter: "x", modifiers: [.alt, .shift])),
            Data("\u{1B}X".utf8)
        )
    }

    func testAmbiguousAndUnsupportedChordsAreRejectedWithoutApproximation() {
        XCTAssertEqual(
            failedError(for: TerminalControlChord(baseKey: .letter, letter: "p", modifiers: [.control, .shift])),
            .ambiguousControlShift
        )
        XCTAssertEqual(
            failedError(for: TerminalControlChord(baseKey: .letter, letter: "p", modifiers: [.control, .alt])),
            .unsupportedControlAlt
        )
        XCTAssertEqual(
            failedError(for: TerminalControlChord(baseKey: .upArrow, modifiers: [.alt])),
            .unsupportedModifiers
        )
    }

    func testPersistenceRoundTripEmptyCollectionAndMalformedData() throws {
        let suiteName = "TerminalControlKeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TerminalControlKeyStore(defaults: defaults, key: "controls")
        let controls = [TerminalControlKey(id: "terminal.custom.one", name: "One", chord: controlLetter("a"))]

        XCTAssertEqual(store.load(), .uninitialized)
        store.save(controls)
        XCTAssertEqual(store.load(), .controls(controls))
        store.save([])
        XCTAssertEqual(store.load(), .controls([]))
        defaults.set(Data([0x00, 0x01]), forKey: "controls")
        XCTAssertEqual(store.load(), .malformed)
    }

    func testEditingNameOrChordPreservesStableIDAndReorderPreservesControls() {
        let original = TerminalControlKey(id: "terminal.custom.one", name: "Old", chord: controlLetter("c"))
        let renamed = TerminalControlKey(id: original.id, name: "Interrupt", chord: original.chord)
        let rechorded = TerminalControlKey(id: original.id, name: renamed.name, chord: controlLetter("r"))
        let second = TerminalControlKey(id: "terminal.custom.two", name: "Clear", chord: controlLetter("l"))
        let reordered = [second, rechorded]

        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(rechorded.id, original.id)
        XCTAssertEqual(reordered.map(\.id), [second.id, original.id])
        XCTAssertEqual(reordered.map(\.chord), [controlLetter("l"), controlLetter("r")])
    }

    func testDuplicateChordIsRejectedEvenWhenNamesDiffer() {
        let original = TerminalControlKey(id: "terminal.custom.one", name: "Interrupt", chord: controlLetter("c"))
        let duplicate = TerminalControlKey(id: "terminal.custom.two", name: "Stop", chord: controlLetter("c"))

        XCTAssertEqual(duplicate.validationError(among: [original, duplicate]), .duplicateChord)
    }

    @MainActor
    func testSettingsKeepsAnEmptySavedCollectionAndCanRestoreDefaults() throws {
        let suiteName = "TerminalControlKeySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EmptyControlKeyCredentialStore()

        let initial = AppSettings(defaults: defaults, credentialStore: store)
        XCTAssertEqual(initial.terminalControlKeys, TerminalControlKey.defaultControls)

        initial.replaceTerminalControlKeys([])
        let reloadedEmpty = AppSettings(defaults: defaults, credentialStore: store)
        XCTAssertEqual(reloadedEmpty.terminalControlKeys, [])

        let invalid = TerminalControlKey(
            chord: TerminalControlChord(baseKey: .letter, letter: "p", modifiers: [.control, .shift])
        )
        XCTAssertFalse(reloadedEmpty.replaceTerminalControlKeys([invalid]))
        XCTAssertEqual(reloadedEmpty.terminalControlKeys, [])

        reloadedEmpty.restoreDefaultTerminalControlKeys()
        let reloadedDefaults = AppSettings(defaults: defaults, credentialStore: store)
        XCTAssertEqual(reloadedDefaults.terminalControlKeys, TerminalControlKey.defaultControls)
    }

    private func controlLetter(_ letter: String) -> TerminalControlChord {
        TerminalControlChord(baseKey: .letter, letter: letter, modifiers: [.control])
    }

    private func successfulBytes(for chord: TerminalControlChord) -> Data? {
        guard case let .success(bytes) = TerminalControlChordEncoder.encode(chord) else { return nil }
        return bytes
    }

    private func failedError(for chord: TerminalControlChord) -> TerminalControlChordError? {
        guard case let .failure(error) = TerminalControlChordEncoder.encode(chord) else { return nil }
        return error
    }
}

private final class EmptyControlKeyCredentialStore: CredentialStore {
    func string(for account: String) throws -> String? { nil }
    func store(_ value: String, for account: String) throws {}
    func removeValue(for account: String) throws {}
}
