import XCTest
@testable import FarRelay

@MainActor
final class FarRelayStatusTests: XCTestCase {
    func testCriticalEventsCoalesceWithoutRepeatedAnnouncements() {
        let store = FarRelayEventStore(capacity: 2)
        let event = FarRelayEvent(
            severity: .critical,
            category: .connectivity,
            code: .connectionLost,
            summary: "Connection lost",
            safeDetail: "Input stopped.",
            recommendedAction: "Retry.",
            deduplicationKey: "g14.loss.1"
        )

        store.emit(event)
        let announced = store.lastAnnounceableEventID
        store.emit(event)

        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events[0].occurrenceCount, 2)
        XCTAssertEqual(store.lastAnnounceableEventID, announced)
    }

    func testEventHistoryIsBoundedAndKeepsNewestEvents() {
        let store = FarRelayEventStore(capacity: 2)
        for code in [FarRelayEventCode.connectionLost, .connectionFailed, .nvdaDisconnected] {
            store.emit(FarRelayEvent(
                severity: .warning,
                category: .connectivity,
                code: code,
                summary: code.rawValue,
                safeDetail: "Safe detail",
                recommendedAction: "Diagnostics",
                deduplicationKey: code.rawValue
            ))
        }
        XCTAssertEqual(store.events.map(\.code), [.nvdaDisconnected, .connectionFailed])
    }

    func testLeaseGateRejectsStaleControllerGeneration() {
        var gate = ControllerLeaseGate()
        let controller = UUID()
        gate.request()
        gate.grant(controllerID: controller)
        let grantedGeneration = gate.generation
        XCTAssertTrue(gate.allowsInput(controllerID: controller, generation: grantedGeneration))

        gate.lose()
        XCTAssertFalse(gate.allowsInput(controllerID: controller, generation: grantedGeneration))
    }

    func testCompatibilityRejectsMajorSkewAndAcceptsUnknownOptionalCapabilities() {
        XCTAssertEqual(FarRelayCompatibility.evaluate(clientProtocol: 1, hostProtocol: 1), .compatible)
        XCTAssertEqual(
            FarRelayCompatibility.evaluate(clientProtocol: 1, hostProtocol: 2),
            .incompatibleProtocol(expected: 1, received: 2)
        )
        let snapshot = FarRelayCapabilitySnapshot(
            protocolVersion: 1,
            hostVersion: "future",
            platform: .windows,
            capabilities: [FarRelayCapability(rawValue: "future.optional")]
        )
        XCTAssertFalse(snapshot.supports(.controllerLease))
        XCTAssertTrue(snapshot.supports(FarRelayCapability(rawValue: "future.optional")))
    }

    func testOldHostCapabilityPayloadDecodesWithoutFeaturesAndNewFeaturesRemainExtensible() throws {
        let old = try JSONDecoder().decode(
            HostCapabilities.self,
            from: Data("{\"protocol_version\":1,\"host_implementation\":\"farrelay-host\",\"host_version\":\"1.0\",\"operations\":[]}".utf8)
        )
        XCTAssertTrue(old.advertisedFeatures.isEmpty)

        let new = try JSONDecoder().decode(
            HostCapabilities.self,
            from: Data("{\"protocol_version\":1,\"host_implementation\":\"farrelay-host\",\"host_version\":\"future\",\"operations\":[],\"features\":[\"macRemote\",\"future.optional\"]}".utf8)
        )
        XCTAssertTrue(new.advertisedFeatures.contains(.macRemote))
        XCTAssertTrue(new.advertisedFeatures.contains(FarRelayCapability(rawValue: "future.optional")))
    }

    func testStatusReportRedactsSecretsAndContent() {
        let profile = HostProfile(
            displayName: "G14",
            address: "private.example",
            username: "reader",
            platform: .windows,
            nvdaRemote: NVDARemoteCapability(channel: "SECRET_CHANNEL", fingerprint: "SECRET_FINGERPRINT")
        )
        let status = FarRelayComputerStatus(
            primary: "Connected",
            detail: "SSH connected",
            nvda: "NVDA: ready",
            terminalSummary: "1 terminal active",
            controller: "Remote Control: unavailable"
        )
        let report = FarRelayStatusReport.make(profile: profile, status: status, events: [])
        XCTAssertFalse(report.contains("SECRET_CHANNEL"))
        XCTAssertFalse(report.contains("SECRET_FINGERPRINT"))
        XCTAssertFalse(report.contains("private.example"))
        XCTAssertFalse(report.contains("reader"))
    }
}
