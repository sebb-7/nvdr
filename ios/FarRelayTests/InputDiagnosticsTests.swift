import XCTest
@testable import FarRelay

@MainActor
final class InputDiagnosticsTests: XCTestCase {
    func testDiagnosticsAreOptInAndBounded() {
        let diagnostics = InputDiagnosticStore()
        diagnostics.observe(source: .rawPress, hidUsage: 58, pressed: true, virtualKey: VK.f1, result: "mapped")
        XCTAssertTrue(diagnostics.entries.isEmpty)

        diagnostics.isEnabled = true
        for sequence in 0..<205 {
            diagnostics.observe(source: .rawPress, hidUsage: sequence, pressed: true, virtualKey: VK.f1, result: "queued for transmission")
        }
        XCTAssertEqual(diagnostics.entries.count, 200)
        XCTAssertEqual(diagnostics.entries.first?.sequence, 6)
        XCTAssertEqual(diagnostics.entries.last?.sequence, 205)
        XCTAssertTrue(diagnostics.entries.last?.reportLine.contains("VK 112") == true)
    }

    func testReportContainsBuildAndBoundaryMetadataButNotTypedContent() {
        let diagnostics = InputDiagnosticStore()
        diagnostics.isEnabled = true
        diagnostics.observe(source: .keyCommand, modifiers: 4, pressed: true, virtualKey: VK.f1, result: "queued for transmission")

        let report = diagnostics.report(connectionState: "NVDA connected", hostVersion: "protocol 1")
        XCTAssertTrue(report.contains("App version:"))
        XCTAssertTrue(report.contains("TestFlight build:"))
        XCTAssertTrue(report.contains("Source revision:"))
        XCTAssertTrue(report.contains("Transport delivery: see per-event routing and transport stages below"))
        XCTAssertTrue(report.contains("Capture coverage: UIKit envelopes include presses with no UIKey"))
        XCTAssertTrue(report.contains("Media command handlers: diagnostics do not register MPRemoteCommandCenter handlers"))
        XCTAssertTrue(report.contains("key command"))
        XCTAssertFalse(report.contains("typed text"))
    }


    func testRawPlatformMetadataIsReportedWithoutKeyCharacters() {
        let diagnostics = InputDiagnosticStore()
        diagnostics.isEnabled = true
        diagnostics.observe(
            source: .uikitEnvelope,
            hidUsage: 58,
            pressType: 1,
            modifiers: 0,
            pressed: true,
            result: "UIKit delivered UIPress with UIKey"
        )
        diagnostics.observe(
            source: .gameControllerRaw,
            platformCode: 58,
            pressed: true,
            virtualKey: VK.f1,
            result: "GCKeyboard delivered F1-F12 key code"
        )

        let report = diagnostics.report(connectionState: "NVDA connected")
        XCTAssertTrue(report.contains("source=UIKit press envelope"))
        XCTAssertTrue(report.contains("press type 1"))
        XCTAssertTrue(report.contains("source=GCKeyboard raw"))
        XCTAssertTrue(report.contains("platform code 58"))
        XCTAssertFalse(report.contains("key character"))
    }

    func testForwardingResultsGiveAnActionableRejectionReason() {
        XCTAssertEqual(InputForwardingResult.accepted.diagnosticText, "queued for transport write; host receipt unconfirmed")
        XCTAssertEqual(InputForwardingResult.rejected("connection is not ready").diagnosticText, "rejected: connection is not ready")
    }

    func testDiagnosticsIdentifyFunctionCaptureSourcesWithoutRecordingText() {
        let diagnostics = InputDiagnosticStore()
        diagnostics.isEnabled = true
        diagnostics.observe(source: .gameController, pressed: true, virtualKey: VK.f1, result: "mapped")
        diagnostics.observe(source: .commandFallback, virtualKey: VK.f1 + 3, result: "local Command and source key consumed")

        let report = diagnostics.report(connectionState: "NVDA connected")
        XCTAssertTrue(report.contains("GCKeyboard"))
        XCTAssertTrue(report.contains("Command F-key fallback"))
        XCTAssertFalse(report.contains("password"))
    }

    func testControllerDiagnosticHasStableSourceInputAndCorrelation() {
        let diagnostics = InputDiagnosticStore()
        diagnostics.isEnabled = true
        diagnostics.observeController(
            eventID: 42,
            input: .dpadUp,
            pressed: true,
            stage: "Binding lookup: matched Keyboard primary key UP"
        )

        let line = try! XCTUnwrap(diagnostics.entries.first?.reportLine)
        XCTAssertTrue(line.contains("source=controller"))
        XCTAssertTrue(line.contains("controller event #42"))
        XCTAssertTrue(line.contains("controller:dpadUp"))
        XCTAssertTrue(line.contains("Binding lookup: matched"))
    }

    func testReportIncludesExistingHostInputEvidenceWithoutClaimingNVDAExecution() {
        let report = InputDiagnosticStore().report(
            connectionState: "NVDA connected",
            hostInputEvidence: ["farrelay: farrelay-ipc: stdin got: key 38 1"]
        )

        XCTAssertTrue(report.contains("Host input evidence"))
        XCTAssertTrue(report.contains("stdin got: key 38 1"))
        XCTAssertTrue(report.contains("NVDA execution unconfirmed"))
    }
}
