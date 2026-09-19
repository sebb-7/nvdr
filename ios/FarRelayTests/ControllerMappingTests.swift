import XCTest
@testable import FarRelay

@MainActor
final class ControllerMappingTests: XCTestCase {
    func testEveryDualSenseInputHasAnIndependentBindingSlot() {
        var profile = ControllerProfile()
        XCTAssertEqual(Set(profile.bindings.map(\.sourceInput)), Set(ControllerInput.allCases))
        profile.setAction(.keyboard(.init(key: .up)), for: .dpadUp)
        profile.setAction(.keyboard(.init(key: .windows, modifiers: [.control])), for: .dpadDown)
        XCTAssertEqual(profile.action(for: .dpadUp), .keyboard(.init(key: .up)))
        XCTAssertEqual(profile.action(for: .dpadDown), .keyboard(.init(key: .windows, modifiers: [.control])))
    }

    func testEverySupportedKeyboardDestinationHasAUniqueWindowsVirtualKey() {
        let keys = WindowsKeyboardKey.allCases
        XCTAssertEqual(Set(keys.map(\.virtualKey)).count, keys.count)
    }

    func testChordCodableRoundTripPreservesModifiers() throws {
        let binding = ControllerBinding(sourceInput: .triangle, action: .keyboard(.init(key: .d, modifiers: [.windows, .control])))
        XCTAssertEqual(try JSONDecoder().decode(ControllerBinding.self, from: JSONEncoder().encode(binding)), binding)
    }

    func testProfilePersistsAndReloads() {
        let defaults = makeDefaults()
        let store = ControllerProfileStore(defaults: defaults, key: "profile")
        var profile = ControllerProfile(name: "NVDA Desktop")
        profile.setAction(.keyboard(.init(key: .tab, modifiers: [.shift])), for: .leftShoulder)
        store.save(profile)
        XCTAssertEqual(store.load(), .profile(profile))
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

    private func makeDefaults() -> UserDefaults {
        let name = "ControllerMappingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
