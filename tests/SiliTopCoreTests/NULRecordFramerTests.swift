import Foundation
import XCTest
@testable import SiliTopCore

final class NULRecordFramerTests: XCTestCase {
    func testPushReassemblesFragmentedRecords() {
        var framer = NULRecordFramer(maxRecordBytes: 1_024)

        let first = framer.push(Data("one\0tw".utf8))
        let second = framer.push(Data("o\0".utf8))

        XCTAssertEqual(first.map { String(decoding: $0, as: UTF8.self) }, ["one"])
        XCTAssertEqual(second.map { String(decoding: $0, as: UTF8.self) }, ["two"])
    }

    func testOversizedRecordIsDroppedAndNextRecordRecovers() {
        var framer = NULRecordFramer(maxRecordBytes: 8)

        XCTAssertTrue(framer.push(Data("123456789".utf8)).isEmpty)
        let records = framer.push(Data("ignored\0ok\0".utf8))

        XCTAssertEqual(records.map { String(decoding: $0, as: UTF8.self) }, ["ok"])
        XCTAssertEqual(framer.droppedRecordCount, 1)
    }

    func testSingleHugeChunkIsDroppedWithoutRetainingItAndRecoversInSamePush() {
        var framer = NULRecordFramer(maxRecordBytes: 1_024)
        var chunk = Data(repeating: UInt8(ascii: "x"), count: 2 * 1_024 * 1_024)
        chunk.append(0)
        chunk.append(Data("ok\0".utf8))

        XCTAssertEqual(framer.push(chunk), [Data("ok".utf8)])
        XCTAssertEqual(framer.droppedRecordCount, 1)
    }
}
