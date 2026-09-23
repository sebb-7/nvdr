import Foundation
import XCTest
@testable import FarRelay

final class BridgeOutputLineFramerTests: XCTestCase {
    func testFragmentedHostDiagnosticIsNotRecordedUntilItsNewlineArrives() {
        var framer = BridgeOutputLineFramer()

        XCTAssertEqual(framer.append(Data("farrelay-ipc: relay key event=418 vk=116 pressed=".utf8)), [])
        XCTAssertEqual(framer.append(Data("true\r".utf8)), [])
        XCTAssertEqual(
            framer.append(Data("\n".utf8)),
            ["farrelay-ipc: relay key event=418 vk=116 pressed=true"]
        )
    }

    func testMultipleLinesAndSplitUTF8AreFramedByteExactly() {
        var framer = BridgeOutputLineFramer()
        let bytes = Array("state ready\nspeak café\n".utf8)
        let split = bytes.firstIndex(of: 0xC3)!

        XCTAssertEqual(framer.append(Data(bytes[..<split])), ["state ready"])
        XCTAssertEqual(framer.append(Data(bytes[split...])), ["speak café"])
    }

    func testUnterminatedSuffixIsReturnedOnlyWhenStreamCloses() {
        var framer = BridgeOutputLineFramer()

        XCTAssertEqual(framer.append(Data("farrelay-ipc: stdin got: key 116 1 event=418".utf8)), [])
        XCTAssertEqual(framer.finish(), "farrelay-ipc: stdin got: key 116 1 event=418")
        XCTAssertNil(framer.finish())
    }
}
