import Darwin
import Foundation
import XCTest
@testable import SiliTopCore

final class SpawnedChildTests: XCTestCase {
    func testOnePipeDrainHasAnExplicitMemoryBound() throws {
        let child = try SpawnedChild.spawn(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import os,time; os.write(1,b'x'*1048576); time.sleep(1)"]
        )
        defer { child.cleanup() }
        usleep(10_000)

        XCTAssertLessThanOrEqual(child.readStdout(maximumBytes: 4_096).count, 4_096)
    }

    func testSpawnStreamsStdoutAndStderrThroughNonblockingPipes() throws {
        let child = try SpawnedChild.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "printf native; printf warning >&2"]
        )
        defer { child.cleanup() }

        XCTAssertNotNil(waitForExit(child))
        XCTAssertEqual(String(decoding: child.readStdout(), as: UTF8.self), "native")
        XCTAssertEqual(String(decoding: child.readStderr(), as: UTF8.self), "warning")
        XCTAssertNotEqual(fcntl(child.stdoutFD, F_GETFL), -1)
        XCTAssertNotEqual(fcntl(child.stdoutFD, F_GETFL) & O_NONBLOCK, 0)
    }

    func testCleanupTerminatesAndReapsLiveChildIdempotently() throws {
        let child = try SpawnedChild.spawn(executable: "/bin/sleep", arguments: ["10"])

        child.cleanup(graceMilliseconds: 20)
        child.cleanup(graceMilliseconds: 20)

        var status: Int32 = 0
        XCTAssertEqual(waitpid(child.pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testConcurrentChildrenHaveIndependentDescriptorsAndOutput() throws {
        let first = try SpawnedChild.spawn(executable: "/bin/echo", arguments: ["first"])
        let second = try SpawnedChild.spawn(executable: "/bin/echo", arguments: ["second"])
        defer { first.cleanup(); second.cleanup() }

        _ = waitForExit(first)
        _ = waitForExit(second)

        XCTAssertNotEqual(first.stdoutFD, second.stdoutFD)
        XCTAssertEqual(String(decoding: first.readStdout(), as: UTF8.self), "first\n")
        XCTAssertEqual(String(decoding: second.readStdout(), as: UTF8.self), "second\n")
    }

    private func waitForExit(_ child: SpawnedChild) -> Int32? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let status = child.reapIfExited() { return status }
            usleep(1_000)
        }
        return nil
    }
}
