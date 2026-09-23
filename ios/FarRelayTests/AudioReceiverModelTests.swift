import XCTest
@testable import FarRelay

@MainActor
final class AudioReceiverModelTests: XCTestCase {
    func testDiagnosticReportNeverIncludesPasswordOrDerivedFingerprint() {
        let password = "only-for-diagnostic-redaction-test"
        let model = AudioReceiverModel()
        model.start(host: "127.0.0.1", port: 47_942, password: password)
        let profile = HostProfile(
            displayName: "Diagnostic PC",
            address: "127.0.0.1",
            username: "user",
            remSoundReceiver: .init(isEnabled: true, senderHost: "127.0.0.1", senderPort: 47_942)
        )

        let report = model.diagnosticReport(profile: profile)
        XCTAssertFalse(report.contains(password))
        XCTAssertFalse(report.contains(RemSoundCrypto.fingerprint(password: password).base64EncodedString()))
        XCTAssertTrue(report.contains("Receiver listening:"))
        model.stop()
    }
}
