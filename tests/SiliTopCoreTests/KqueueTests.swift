import Darwin
import XCTest
@testable import SiliTopCore

final class KqueueTests: XCTestCase {
    func testReadEventIdentifiesReadyDescriptor() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { Darwin.close(descriptors[0]); Darwin.close(descriptors[1]) }
        let queue = try Kqueue()
        try queue.watchRead(descriptors[0])

        var byte: UInt8 = 1
        XCTAssertEqual(Darwin.write(descriptors[1], &byte, 1), 1)
        let events = try queue.wait(maxEvents: 4, timeoutMilliseconds: 100)

        XCTAssertTrue(events.contains(.read(descriptors[0])))
    }

    func testPipeEOFIsNotReportedAsOrdinaryReadableData() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { Darwin.close(descriptors[0]) }
        let queue = try Kqueue()
        try queue.watchRead(descriptors[0])

        XCTAssertEqual(Darwin.close(descriptors[1]), 0)
        let events = try queue.wait(maxEvents: 4, timeoutMilliseconds: 100)

        XCTAssertFalse(events.contains(.read(descriptors[0])))
        XCTAssertTrue(events.contains(.readEOF(descriptors[0])))
    }

    func testProcessExitEventCarriesChildPID() throws {
        let child = try SpawnedChild.spawn(executable: "/usr/bin/true", arguments: [])
        defer { child.cleanup() }
        let queue = try Kqueue()
        try queue.watchProcess(child.pid)

        let events = try queue.wait(maxEvents: 4, timeoutMilliseconds: 500)

        XCTAssertTrue(events.contains(.processExit(child.pid)))
    }

    func testOneShotTimerWakesLoop() throws {
        let queue = try Kqueue()
        try queue.watchTimer(identifier: 9, milliseconds: 5, repeating: false)

        let events = try queue.wait(maxEvents: 4, timeoutMilliseconds: 100)

        XCTAssertTrue(events.contains(.timer(9)))
    }

    func testSignalEventIsDeliveredWithoutRunningDefaultHandler() throws {
        let queue = try Kqueue()
        try queue.watchSignal(SIGWINCH)
        XCTAssertEqual(Darwin.kill(getpid(), SIGWINCH), 0)

        let events = try queue.wait(maxEvents: 4, timeoutMilliseconds: 100)

        XCTAssertTrue(events.contains(.signal(SIGWINCH)))
    }
}
