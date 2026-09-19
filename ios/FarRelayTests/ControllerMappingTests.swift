import XCTest
@testable import FarRelay

@MainActor
final class ControllerMappingTests: XCTestCase {
    func testBindingEditorStateKeepsUnassignedDistinctFromUpArrow() {
        let unassigned = ControllerBindingEditorState(action: nil)
        XCTAssertNil(unassigned.key)
        XCTAssertNil(unassigned.action)

        var upArrow = unassigned
        upArrow.key = .up
        XCTAssertEqual(upArrow.action, .keyboard(.init(key: .up)))

        let existing = ControllerBindingEditorState(
            action: .keyboard(.init(key: .tab, modifiers: [.shift]))
        )
        XCTAssertEqual(existing.key, .tab)
        XCTAssertEqual(existing.modifiers, [.shift])
        XCTAssertEqual(
            existing.action,
            .keyboard(.init(key: .tab, modifiers: [.shift]))
        )
    }

    func testEveryDualSenseInputHasAnIndependentBindingSlot() {
        var profile = ControllerProfile()
        XCTAssertEqual(Set(profile.bindings.map(\.sourceInput)), Set(ControllerInput.allCases))
        profile.setAction(.keyboard(.init(key: .up)), for: .dpadUp)
        profile.setAction(.keyboard(.init(key: .windows, modifiers: [.control])), for: .dpadDown)
        XCTAssertEqual(profile.action(for: .dpadUp), .keyboard(.init(key: .up)))
        XCTAssertEqual(profile.action(for: .dpadDown), .keyboard(.init(key: .windows, modifiers: [.control])))
        profile.setAction(.keyboard(.init(key: .escape)), for: .home)
        XCTAssertEqual(profile.action(for: .home), .keyboard(.init(key: .escape)))
    }

    func testEverySupportedKeyboardDestinationHasAUniqueWindowsVirtualKey() {
        let keys = WindowsKeyboardKey.allCases
        XCTAssertEqual(Set(keys.map(\.virtualKey)).count, keys.count)
    }

    func testChordCodableRoundTripPreservesModifiers() throws {
        let binding = ControllerBinding(sourceInput: .triangle, action: .keyboard(.init(key: .d, modifiers: [.windows, .control])))
        XCTAssertEqual(try JSONDecoder().decode(ControllerBinding.self, from: JSONEncoder().encode(binding)), binding)
    }

    func testEveryControllerInputHasAStableCodableIdentifier() throws {
        let encoded = try JSONEncoder().encode(ControllerInput.allCases)
        XCTAssertEqual(try JSONDecoder().decode([ControllerInput].self, from: encoded), ControllerInput.allCases)
    }

    func testProfilePersistsAndReloads() {
        let defaults = makeDefaults()
        let store = ControllerProfileStore(defaults: defaults, key: "profile")
        var profile = ControllerProfile(name: "NVDA Desktop")
        profile.setAction(.keyboard(.init(key: .tab, modifiers: [.shift])), for: .leftShoulder)
        store.save(profile)
        XCTAssertEqual(store.load(), .profile(profile))
    }

    func testEditsRemainInDraftUntilSaveMappingsThenReloadAtomically() {
        let defaults = makeDefaults()
        let settings = ControllerMappingSettings(defaults: defaults)

        settings.setAction(.keyboard(.init(key: .tab)), for: .dpadUp)
        settings.setAction(.keyboard(.init(key: .escape)), for: .dpadDown)

        XCTAssertTrue(settings.hasUnsavedChanges)
        XCTAssertEqual(settings.activeProfile.action(for: .dpadUp), .keyboard(.init(key: .up)))
        XCTAssertEqual(settings.draftProfile.action(for: .dpadUp), .keyboard(.init(key: .tab)))

        settings.saveDraft()

        XCTAssertFalse(settings.hasUnsavedChanges)
        XCTAssertEqual(settings.activeProfile.action(for: .dpadUp), .keyboard(.init(key: .tab)))
        XCTAssertEqual(settings.activeProfile.action(for: .dpadDown), .keyboard(.init(key: .escape)))
        let reloaded = ControllerMappingSettings(defaults: defaults)
        XCTAssertEqual(reloaded.activeProfile, settings.activeProfile)
    }

    func testDiscardingDraftNeverPersistsIt() {
        let defaults = makeDefaults()
        let settings = ControllerMappingSettings(defaults: defaults)
        settings.setAction(.keyboard(.init(key: .tab)), for: .dpadUp)
        settings.discardDraft()

        XCTAssertFalse(settings.hasUnsavedChanges)
        XCTAssertEqual(ControllerMappingSettings(defaults: defaults).activeProfile.action(for: .dpadUp), .keyboard(.init(key: .up)))
    }

    func testCorruptOrFutureProfileFailsClosed() throws {
        let defaults = makeDefaults()
        let store = ControllerProfileStore(defaults: defaults, key: "profile")
        defaults.set(Data("not json".utf8), forKey: "profile")
        XCTAssertEqual(store.load(), .malformedOrUnsupported)
        var profile = ControllerProfile()
        profile.schemaVersion += 1
        defaults.set(try JSONEncoder().encode(profile), forKey: "profile")
        XCTAssertEqual(store.load(), .malformedOrUnsupported)
    }

    func testV1ProfileMigratesWithoutChangingExistingBaseBinding() throws {
        let defaults = makeDefaults()
        let store = ControllerProfileStore(defaults: defaults, key: "profile")
        var legacy = ControllerProfile(schemaVersion: 1)
        legacy.setAction(.keyboard(.init(key: .escape)), for: .circle)
        store.save(legacy)

        guard case .profile(let migrated) = store.load() else {
            return XCTFail("Expected v1 profile migration")
        }
        XCTAssertEqual(migrated.schemaVersion, ControllerProfile.currentSchemaVersion)
        XCTAssertEqual(migrated.action(for: .circle), .keyboard(.init(key: .escape)))
        XCTAssertEqual(migrated.layers.first?.id, ControllerLayerDefinition.extendedID)
    }

    func testLegacyProfileFixturePreservesEveryExistingBinding() throws {
        let defaults = makeDefaults()
        let store = ControllerProfileStore(defaults: defaults, key: "profile")
        let id = UUID()
        let fixture = """
        {"schemaVersion":1,"id":"\(id.uuidString)","name":"Legacy","controller":"dualSense","bindings":[{"sourceInput":"dpadUp","action":{"keyboard":{"_0":{"key":"tab","modifiers":["shift"]}}}},{"sourceInput":"circle","action":null}]}
        """
        defaults.set(Data(fixture.utf8), forKey: "profile")
        guard case .profile(let migrated) = store.load() else { return XCTFail("Expected legacy fixture to load") }
        XCTAssertEqual(migrated.id, id)
        XCTAssertEqual(migrated.name, "Legacy")
        XCTAssertEqual(migrated.controller, .dualSense)
        XCTAssertEqual(migrated.action(for: .dpadUp), .keyboard(.init(key: .tab, modifiers: [.shift])))
        XCTAssertNil(migrated.action(for: .circle))
        XCTAssertNil(migrated.action(for: .options))
        XCTAssertEqual(migrated.layers.map(\.id), [ControllerLayerDefinition.extendedID])
        XCTAssertEqual(migrated.schemaVersion, ControllerProfile.currentSchemaVersion)
    }

    func testDuplicateLayerIdentifiersFailClosed() throws {
        let defaults = makeDefaults()
        let store = ControllerProfileStore(defaults: defaults, key: "profile")
        var profile = ControllerProfile()
        let bindings = ControllerInput.allCases.map { ControllerBinding(sourceInput: $0, action: nil) }
        profile.layers = [
            .init(id: "extended", name: "Extended", bindings: bindings),
            .init(id: "extended", name: "Duplicate", bindings: bindings)
        ]
        store.save(profile)
        XCTAssertEqual(store.load(), .malformedOrUnsupported)
    }

    func testMissingNewBindingSlotLoadsAsUnassignedButDuplicateSlotsFailClosed() throws {
        let defaults = makeDefaults()
        let store = ControllerProfileStore(defaults: defaults, key: "profile")
        var olderShape = ControllerProfile()
        olderShape.bindings.removeAll { $0.sourceInput == .home }
        defaults.set(try JSONEncoder().encode(olderShape), forKey: "profile")
        guard case .profile(let normalized) = store.load() else { return XCTFail("Expected safe slot normalization") }
        XCTAssertNil(normalized.action(for: .home))

        var duplicate = ControllerProfile()
        duplicate.bindings.append(.init(sourceInput: .dpadUp, action: .keyboard(.init(key: .escape))))
        defaults.set(try JSONEncoder().encode(duplicate), forKey: "profile")
        XCTAssertEqual(store.load(), .malformedOrUnsupported)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "ControllerMappingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
