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

    func testHoldModifierEditorAndCodableRoundTrip() throws {
        let action = ControllerAction.stickyModifier(.init(modifier: .alt))
        let state = ControllerBindingEditorState(action: action)
        XCTAssertEqual(state.type, .stickyModifier)
        XCTAssertEqual(state.stickyModifier, .alt)
        XCTAssertEqual(state.action, action)

        let binding = ControllerBinding(sourceInput: .triangle, action: action)
        XCTAssertEqual(
            try JSONDecoder().decode(ControllerBinding.self, from: JSONEncoder().encode(binding)),
            binding
        )
        XCTAssertFalse(action.isAllowedInQuickBar)
        XCTAssertFalse(action.isRepeatableQuickBarAction)
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

    func testRecommendedLayoutFillsOnlyUnassignedMappingsAndPreservesR1LayerChoice() {
        let defaults = makeDefaults()
        let settings = ControllerMappingSettings(defaults: defaults)

        settings.setAction(.layer(.init()), for: .rightShoulder)
        settings.setAction(.keyboard(.init(key: .f8)), for: .square)
        settings.setAction(.keyboard(.init(key: .f9)), for: .dpadUp, layerID: ControllerLayerDefinition.extendedID)

        let count = settings.fillUnassignedWithRecommendedLayout()

        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(settings.draftProfile.action(for: .rightShoulder), .layer(.init()))
        XCTAssertEqual(settings.draftProfile.action(for: .square), .keyboard(.init(key: .f8)))
        XCTAssertEqual(
            settings.draftProfile.action(for: .dpadUp, layerID: ControllerLayerDefinition.extendedID),
            .keyboard(.init(key: .f9))
        )
        XCTAssertEqual(settings.draftProfile.action(for: .create), .quickNavigation(.toggle))
        XCTAssertEqual(settings.draftProfile.action(for: .touchpadPress), .farRelay(.textMode))
        XCTAssertEqual(
            settings.draftProfile.action(for: .cross, layerID: ControllerLayerDefinition.extendedID),
            .farRelay(.repeatLastQuickBar)
        )
    }

    func testRecommendedLayoutPrefersR1ForLayerWhenNoLayerControlExists() {
        let defaults = makeDefaults()
        let store = ControllerProfileStore(defaults: defaults, key: "farrelay.controllerProfile.v1")
        var profile = ControllerProfile()
        profile.layers = [.init(
            id: ControllerLayerDefinition.extendedID,
            name: "Extended",
            bindings: ControllerInput.allCases.map { .init(sourceInput: $0, action: nil) }
        )]
        store.save(profile)

        let settings = ControllerMappingSettings(defaults: defaults)
        settings.fillUnassignedWithRecommendedLayout()

        XCTAssertEqual(settings.draftProfile.action(for: .rightShoulder), .layer(.init()))
        XCTAssertNil(settings.draftProfile.action(for: .options))
    }

    func testRecommendedLayoutFallsBackToOptionsWhenR1IsAlreadyOccupied() {
        let defaults = makeDefaults()
        let store = ControllerProfileStore(defaults: defaults, key: "farrelay.controllerProfile.v1")
        var profile = ControllerProfile()
        profile.setAction(.keyboard(.init(key: .f7)), for: .rightShoulder)
        profile.layers = [.init(
            id: ControllerLayerDefinition.extendedID,
            name: "Extended",
            bindings: ControllerInput.allCases.map { .init(sourceInput: $0, action: nil) }
        )]
        store.save(profile)

        let settings = ControllerMappingSettings(defaults: defaults)
        settings.fillUnassignedWithRecommendedLayout()

        XCTAssertEqual(settings.draftProfile.action(for: .rightShoulder), .keyboard(.init(key: .f7)))
        XCTAssertEqual(settings.draftProfile.action(for: .options), .layer(.init()))
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

    func testV2ProfileWithoutQuickBarMigratesToRecommendedQuickBar() throws {
        let defaults = makeDefaults()
        let store = ControllerProfileStore(defaults: defaults, key: "profile")
        let id = UUID()
        let fixture = """
        {"schemaVersion":2,"id":"\(id.uuidString)","name":"V2","controller":"dualSense","bindings":[],"layers":[]}
        """
        defaults.set(Data(fixture.utf8), forKey: "profile")

        guard case .profile(let migrated) = store.load() else {
            return XCTFail("Expected v2 migration")
        }
        XCTAssertEqual(migrated.schemaVersion, ControllerProfile.currentSchemaVersion)
        XCTAssertEqual(migrated.name, "V2")
        XCTAssertFalse(migrated.quickBar.isEmpty)
    }

    func testProfileLibraryRejectsDuplicateIDsAndMissingActiveProfile() {
        let defaults = makeDefaults()
        let store = ControllerProfileLibraryStore(defaults: defaults, key: "library")
        let profile = ControllerProfile.newDefault(name: "Desktop")

        store.save(.init(activeProfileID: profile.id, profiles: [profile, profile]))
        XCTAssertEqual(store.load(), .malformedOrUnsupported)

        let otherID = UUID()
        store.save(.init(activeProfileID: otherID, profiles: [profile]))
        XCTAssertEqual(store.load(), .malformedOrUnsupported)
    }

    func testLegacySingleProfileMigratesIntoProfileLibraryWithoutChangingMapping() {
        let defaults = makeDefaults()
        let legacyStore = ControllerProfileStore(defaults: defaults, key: "farrelay.controllerProfile.v1")
        var legacy = ControllerProfile.newDefault(name: "My Desktop")
        legacy.setAction(.keyboard(.init(key: .f8)), for: .square)
        legacyStore.save(legacy)

        let settings = ControllerMappingSettings(defaults: defaults)

        XCTAssertEqual(settings.profiles.count, 1)
        XCTAssertEqual(settings.activeProfile.name, "My Desktop")
        XCTAssertEqual(settings.activeProfile.action(for: .square), .keyboard(.init(key: .f8)))
        XCTAssertEqual(settings.activeProfileID, legacy.id)
    }

    func testMalformedLegacyProfileBytesArePreservedDuringLibraryBootstrap() {
        let defaults = makeDefaults()
        let key = "farrelay.controllerProfile.v1"
        let bytes = Data("DO_NOT_OVERWRITE".utf8)
        defaults.set(bytes, forKey: key)

        _ = ControllerMappingSettings(defaults: defaults)

        XCTAssertEqual(defaults.data(forKey: key), bytes)
    }

    func testQuickBarEditsUseSameControllerActionModelAndPersistAtomically() {
        let defaults = makeDefaults()
        let settings = ControllerMappingSettings(defaults: defaults)
        let originalCount = settings.draftProfile.quickBar.count
        let entryID = settings.addQuickBarEntry(action: .farRelay(.nextProfile))
        XCTAssertEqual(settings.draftProfile.quickBar.count, originalCount + 1)
        XCTAssertEqual(
            settings.draftProfile.quickBar.first(where: { $0.id == entryID })?.action,
            .farRelay(.nextProfile)
        )
        XCTAssertTrue(settings.hasUnsavedChanges)

        settings.saveDraft()
        let reloaded = ControllerMappingSettings(defaults: defaults)
        XCTAssertEqual(
            reloaded.activeProfile.quickBar.first(where: { $0.id == entryID })?.action,
            .farRelay(.nextProfile)
        )
    }

    func testCreateProfileForEditingSavesCurrentDraftAndSelectsNewDraft() {
        let defaults = makeDefaults()
        let settings = ControllerMappingSettings(defaults: defaults)
        let originalID = settings.activeProfileID

        settings.renameDraftProfile("Desktop")
        XCTAssertTrue(settings.hasUnsavedChanges)

        let newID = settings.createProfileForEditing(name: "Gaming")

        XCTAssertEqual(settings.editingProfileID, newID)
        XCTAssertEqual(settings.draftProfile.id, newID)
        XCTAssertEqual(settings.draftProfile.name, "Gaming")
        XCTAssertFalse(settings.hasUnsavedChanges)
        XCTAssertEqual(settings.profiles.first(where: { $0.id == originalID })?.name, "Desktop")

        let reloaded = ControllerMappingSettings(defaults: defaults)
        XCTAssertEqual(reloaded.profiles.first(where: { $0.id == originalID })?.name, "Desktop")
        XCTAssertEqual(reloaded.profiles.first(where: { $0.id == newID })?.name, "Gaming")
    }

    func testQuickBarAndRotorOrderMoveDeterministicallyAndPersist() {
        let defaults = makeDefaults()
        let settings = ControllerMappingSettings(defaults: defaults)

        let firstQuickBarID = settings.draftProfile.quickBar[0].id
        settings.moveQuickBarEntry(id: firstQuickBarID, direction: 1)
        XCTAssertEqual(settings.draftProfile.quickBar[1].id, firstQuickBarID)

        settings.moveQuickNavigationCategory(.editing, direction: -1)
        XCTAssertEqual(
            Array(settings.draftProfile.quickNavigationOrder.prefix(3)),
            [.quickBar, .editing, .profiles]
        )

        settings.saveDraft()
        let reloaded = ControllerMappingSettings(defaults: defaults)
        XCTAssertEqual(reloaded.activeProfile.quickBar[1].id, firstQuickBarID)
        XCTAssertEqual(
            Array(reloaded.activeProfile.quickNavigationOrder.prefix(3)),
            [.quickBar, .editing, .profiles]
        )
    }

    func testAccessibleReorderOperationsReportPositionsAndRespectEdges() {
        let defaults = makeDefaults()
        let settings = ControllerMappingSettings(defaults: defaults)

        let firstQuickBarID = settings.draftProfile.quickBar[0].id
        XCTAssertNil(settings.moveQuickBarEntry(id: firstQuickBarID, direction: -1))
        XCTAssertNil(settings.moveQuickBarEntryToStart(id: firstQuickBarID))
        XCTAssertEqual(
            settings.moveQuickBarEntryToEnd(id: firstQuickBarID),
            settings.draftProfile.quickBar.count - 1
        )
        XCTAssertEqual(settings.draftProfile.quickBar.last?.id, firstQuickBarID)
        XCTAssertNil(settings.moveQuickBarEntryToEnd(id: firstQuickBarID))
        XCTAssertEqual(settings.moveQuickBarEntryToStart(id: firstQuickBarID), 0)
        XCTAssertEqual(settings.draftProfile.quickBar.first?.id, firstQuickBarID)

        XCTAssertNil(settings.moveQuickNavigationCategory(.quickBar, direction: -1))
        XCTAssertNil(settings.moveQuickNavigationCategoryToStart(.quickBar))
        XCTAssertEqual(
            settings.moveQuickNavigationCategoryToEnd(.quickBar),
            settings.draftProfile.quickNavigationOrder.count - 1
        )
        XCTAssertEqual(settings.draftProfile.quickNavigationOrder.last, .quickBar)
        XCTAssertNil(settings.moveQuickNavigationCategoryToEnd(.quickBar))
        XCTAssertEqual(settings.moveQuickNavigationCategoryToStart(.quickBar), 0)
        XCTAssertEqual(settings.draftProfile.quickNavigationOrder.first, .quickBar)
    }

    func testV3ProfileMigratesWithRecommendedRotorOrder() throws {
        let defaults = makeDefaults()
        let store = ControllerProfileStore(defaults: defaults, key: "profile")
        let id = UUID()
        let fixture = """
        {"schemaVersion":3,"id":"\(id.uuidString)","name":"V3","controller":"dualSense","bindings":[],"layers":[],"quickBar":[]}
        """
        defaults.set(Data(fixture.utf8), forKey: "profile")

        guard case .profile(let migrated) = store.load() else {
            return XCTFail("Expected v3 profile migration")
        }
        XCTAssertEqual(migrated.schemaVersion, ControllerProfile.currentSchemaVersion)
        XCTAssertEqual(migrated.quickNavigationOrder, QuickNavigationCategory.defaultOrder)
        XCTAssertTrue(migrated.quickBar.isEmpty)
    }

    func testProfileCycleUsesSavedOrderAndWraps() {
        let defaults = makeDefaults()
        let settings = ControllerMappingSettings(defaults: defaults)
        let firstID = settings.activeProfileID
        let secondID = settings.createProfile(name: "Hearthstone")
        let thirdID = settings.createProfile(name: "Discord")

        XCTAssertEqual(settings.activateNextProfile(), "Hearthstone")
        XCTAssertEqual(settings.activeProfileID, secondID)
        XCTAssertEqual(settings.activateNextProfile(), "Discord")
        XCTAssertEqual(settings.activeProfileID, thirdID)
        XCTAssertEqual(settings.activateNextProfile(), settings.profiles.first?.name)
        XCTAssertEqual(settings.activeProfileID, firstID)
        XCTAssertEqual(settings.activatePreviousProfile(), "Discord")
        XCTAssertEqual(settings.activeProfileID, thirdID)
    }

    func testCannotDeleteOnlyRemainingProfile() {
        let defaults = makeDefaults()
        let settings = ControllerMappingSettings(defaults: defaults)
        XCTAssertFalse(settings.deleteProfile(id: settings.activeProfileID))
        XCTAssertEqual(settings.profiles.count, 1)
    }

    func testBindingEditorRoundTripsFarRelayProfileActions() {
        for action in [
            FarRelayControllerAction.textMode,
            .quickCommandMode,
            .repeatLastQuickBar,
            .nextProfile,
            .previousProfile
        ] {
            let state = ControllerBindingEditorState(action: .farRelay(action))
            XCTAssertEqual(state.action, .farRelay(action))
        }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "ControllerMappingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
