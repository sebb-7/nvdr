import XCTest
@testable import FarRelay

@MainActor
final class PortableControllerProfileTests: XCTestCase {
    func testPortableProfileRoundTripPreservesControllerExperience() throws {
        let original = makeProfile()
        let manifest = FarRelayControllerProfileManifest(profile: original)
        let data = try FarRelayProfileCodec.encode(manifest)
        let decoded = try FarRelayProfileCodec.decode(data)
        let restored = try decoded.makeControllerProfile(id: original.id)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.name, original.name)
        XCTAssertEqual(restored.controller, original.controller)
        XCTAssertEqual(restored.bindings, original.bindings)
        XCTAssertEqual(restored.layers, original.layers)
        XCTAssertEqual(
            restored.quickBar.map(\.action),
            original.quickBar.map(\.action)
        )
        XCTAssertEqual(
            restored.quickNavigationOrder,
            original.quickNavigationOrder
        )
        XCTAssertEqual(
            restored.quickNavigationAutoExitAfterAction,
            original.quickNavigationAutoExitAfterAction
        )
    }

    func testPortableJSONUsesStableHumanReadableSchema() throws {
        let data = try FarRelayProfileCodec.encode(
            FarRelayControllerProfileManifest(profile: makeProfile())
        )
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains(#""format" : "farrelay.controller-profile""#))
        XCTAssertTrue(json.contains(#""actionBar""#))
        XCTAssertTrue(json.contains(#""type" : "keyboard""#))
        XCTAssertTrue(json.contains(#""rotor""#))
        XCTAssertFalse(json.contains(#""_0""#))
        XCTAssertFalse(json.contains(#""schemaVersion""#))
    }

    func testUnsupportedFutureVersionFailsBeforeSettingsMutation() throws {
        let defaults = makeDefaults()
        let settings = ControllerMappingSettings(defaults: defaults)
        let originalProfiles = settings.profiles
        var manifest = FarRelayControllerProfileManifest(profile: makeProfile())
        manifest.version = FarRelayControllerProfileManifest.currentVersion + 1
        let data = try JSONEncoder().encode(manifest)

        XCTAssertThrowsError(try settings.importPortableProfileData(data))
        XCTAssertEqual(settings.profiles, originalProfiles)
    }

    func testUnknownActionFailsClosed() throws {
        var manifest = FarRelayControllerProfileManifest(profile: makeProfile())
        manifest.profile.mappings[0].action = FarRelayPortableAction(
            type: "unknown-action"
        )

        XCTAssertThrowsError(try manifest.makeControllerProfile()) { error in
            XCTAssertEqual(
                error as? FarRelayProfileFileError,
                .unsupportedAction("unknown-action")
            )
        }
    }

    func testDuplicateBindingFailsClosed() throws {
        var manifest = FarRelayControllerProfileManifest(profile: makeProfile())
        manifest.profile.mappings.append(manifest.profile.mappings[0])

        XCTAssertThrowsError(try manifest.makeControllerProfile())
    }

    func testImportCreatesNewProfileAndKeepsExistingProfile() throws {
        let defaults = makeDefaults()
        let settings = ControllerMappingSettings(defaults: defaults)
        let originalID = settings.activeProfileID
        var imported = makeProfile()
        imported.name = settings.activeProfile.name

        let importedID = try settings.importPortableProfile(
            FarRelayControllerProfileManifest(profile: imported)
        )

        XCTAssertEqual(settings.profiles.count, 2)
        XCTAssertEqual(settings.activeProfileID, originalID)
        XCTAssertNotEqual(importedID, originalID)
        XCTAssertEqual(
            settings.profiles.first(where: { $0.id == importedID })?.name,
            "\(settings.activeProfile.name) (2)"
        )
    }

    func testFRFileExtensionIsCanonical() {
        XCTAssertEqual(FarRelayProfileFileName.fileExtension, "fr")
    }

    func testOpenInFarRelayRecognizesFRCaseInsensitively() {
        XCTAssertTrue(
            FarRelayProfileFileImport.canOpen(
                URL(fileURLWithPath: "/tmp/NVDA-Web-Navigation.fr")
            )
        )
        XCTAssertTrue(
            FarRelayProfileFileImport.canOpen(
                URL(fileURLWithPath: "/tmp/NVDA-Web-Navigation.FR")
            )
        )
        XCTAssertFalse(
            FarRelayProfileFileImport.canOpen(
                URL(fileURLWithPath: "/tmp/NVDA-Web-Navigation.json")
            )
        )
        XCTAssertFalse(
            FarRelayProfileFileImport.canOpen(
                URL(string: "https://example.com/profile.fr")!
            )
        )
    }

    func testOpenInFarRelayUsesValidatedPortableCodec() throws {
        let manifest = FarRelayControllerProfileManifest(profile: makeProfile())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(FarRelayProfileFileName.fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }

        try FarRelayProfileCodec.encode(manifest).write(to: url, options: .atomic)
        let decoded = try FarRelayProfileFileImport.decode(url)

        XCTAssertEqual(decoded, manifest)
    }

    private func makeProfile() -> ControllerProfile {
        var profile = ControllerProfile.blank(name: "NVDA Web Navigation")
        profile.setAction(
            .keyboard(.init(key: .tab, modifiers: [.shift])),
            for: .leftShoulder
        )
        profile.setAction(
            .stickyModifier(
                .init(modifiers: [.alt, .shift], tapKey: .tab)
            ),
            for: .triangle
        )
        profile.setAction(.layer(.init()), for: .rightShoulder)
        profile.setAction(.quickNavigation(.toggle), for: .touchpadPress)
        profile.setAction(.farRelay(.quickCommandMode), for: .square)
        if let extendedIndex = profile.layers.firstIndex(
            where: { $0.id == ControllerLayerDefinition.extendedID }
        ) {
            profile.layers[extendedIndex].setAction(
                .keyboard(.init(key: .f7, modifiers: [.nvda])),
                for: .cross
            )
        } else {
            XCTFail("Expected Extended layer in blank profile")
        }
        profile.quickNavigationAutoExitAfterAction = false
        profile.quickBar = [
            .init(action: .keyboard(.init(key: .c, modifiers: [.control]))),
            .init(action: .farRelay(.repeatLastQuickCommand)),
            .init(action: nil),
        ]
        profile.quickNavigationOrder = [
            .headings, .links, .formControls, .editFields, .buttons,
            .landmarks, .tables, .lists, .quickBar, .profiles, .editing,
        ]
        return profile
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "PortableControllerProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
