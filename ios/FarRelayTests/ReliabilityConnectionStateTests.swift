import XCTest
@testable import FarRelay

@MainActor
final class ReliabilityConnectionStateTests: XCTestCase {
    func testOfflineConnectionAttemptNeverPresentsDisconnectAsConnected() {
        XCTAssertEqual(NVDARemoteConnectionAction(status: .connecting), .cancel)
        XCTAssertEqual(NVDARemoteConnectionAction(status: .authenticating), .cancel)
        XCTAssertEqual(
            NVDARemoteConnectionAction(status: .failed(message: "Host unreachable")),
            .connect
        )
    }

    func testOnlyUsableSSHBackedStatesOfferDisconnect() {
        XCTAssertEqual(NVDARemoteConnectionAction(status: .relayConnected), .disconnect)
        XCTAssertEqual(NVDARemoteConnectionAction(status: .waitingForNVDA), .disconnect)
        XCTAssertEqual(NVDARemoteConnectionAction(status: .ready), .disconnect)
        XCTAssertEqual(NVDARemoteConnectionAction(status: .nvdaNotConnected), .disconnect)
        XCTAssertEqual(
            NVDARemoteConnectionAction(status: .disconnected(reason: "Connection lost")),
            .connect
        )
    }
}
