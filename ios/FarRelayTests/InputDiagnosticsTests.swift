import XCTest
@testable import FarRelay

@MainActor
final class InputDiagnosticsTests: XCTestCase {
    func testDiagnosticsAreOptInAndBounded() {
        let diagnostics = InputDiagnosticStore()
        diagnostics.observe(source: .rawPress, hidUsage: 58, pressed: true, virtualKey: VK.f1, result: "mapped")
        XCTAssertTrue(diagnostics.entries.isEmpty)

        diagnostics.isEnabled = true
        for sequence in 0..<55 {
            diagnostics.observe(source: .rawPress, hidUsage: sequence, pressed: true, virtualKey: VK.f1, result: "queued for transmission")
        }
        XCTAssertEqual(diagnostics.entries.count, 50)
        XCTAssertEqual(diagnostics.entries.first?.sequence, 6)
        XCTAssertEqual(diagnostics.entries.last?.sequence, 55)
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
        XCTAssertTrue(report.contains("key command"))
        XCTAssertFalse(report.contains("typed text"))
    }

    func testForwardingResultsGiveAnActionableRejectionReason() {
        XCTAssertEqual(InputForwardingResult.accepted.diagnosticText, "queued for transmission")
        XCTAssertEqual(InputForwardingResult.rejected("connection is not ready").diagnosticText, "rejected: connection is not ready")
    }
}
