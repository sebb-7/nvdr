import XCTest
@testable import FarRelay

@MainActor
final class SoundIntentTests: XCTestCase {
    func testSemanticIntentMapsToCanonicalFilenames() {
        XCTAssertEqual(InteractionSoundIntent.remoteConnected.filename, "connected.wav")
        XCTAssertEqual(InteractionSoundIntent.keyboardRemote.filename, "keyboard-remote.wav")
        XCTAssertEqual(InteractionSoundIntent.copied.filename, "copied.wav")
    }

    func testRemoteWaveLookupIsGenericAndSafe() {
        XCTAssertEqual(SoundResourceResolver.remoteWaveFilename(from: "C:\\Program Files\\NVDA\\waves\\browseMode.wav"), "browseMode.wav")
        XCTAssertEqual(SoundResourceResolver.remoteWaveFilename(from: "/usr/share/nvda/waves/focusMode.wav"), "focusMode.wav")
        XCTAssertEqual(SoundResourceResolver.remoteWaveFilename(from: "otherCue.WAV"), "otherCue.WAV")
        XCTAssertNil(SoundResourceResolver.remoteWaveFilename(from: "../../outside.wav"))
        XCTAssertNil(SoundResourceResolver.bundledURL(for: "missing.wav", in: .main))
    }

    func testIPCParsesRemoteSoundEventsAndFailsClosed() {
        guard let tone = RemoteNVDATone(frequency: 440, durationMilliseconds: 100, leftLevel: 50, rightLevel: 50) else {
            return XCTFail("fixture tone should be valid")
        }
        XCTAssertEqual(IPCParser.parse("tone 440 100 50 50"), .tone(tone))
        XCTAssertEqual(IPCParser.parse("wave browseMode.wav"), .wave("browseMode.wav"))
        if case .unknown = IPCParser.parse("tone 440 nope 50 50") {} else { XCTFail("malformed tone must fail closed") }
        if case .unknown = IPCParser.parse("wave ../outside.wav") {} else { XCTFail("unsafe wave must fail closed") }
    }

    func testConnectionAndKeyboardCuesAreTransitionSpecific() {
        XCTAssertEqual(BridgeClient.soundIntent(from: .connecting, to: .ready), .remoteConnected)
        XCTAssertNil(BridgeClient.soundIntent(from: .ready, to: .ready))
        XCTAssertEqual(BridgeClient.soundIntent(from: .ready, to: .disconnected(reason: "relay")), .disconnected)
        XCTAssertNil(BridgeClient.soundIntent(from: .failed(message: "no"), to: .disconnected(reason: "relay")))
        XCTAssertNotEqual(InteractionSoundIntent.keyboardRemote, .keyboardLocal)
    }
}
