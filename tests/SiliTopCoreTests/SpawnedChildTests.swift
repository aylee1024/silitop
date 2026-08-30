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

    func testChildDoesNotInheritDashboardIgnoredTerminationSignals() throws {
        let prior = Darwin.signal(SIGTERM, SIG_IGN)
        defer { _ = Darwin.signal(SIGTERM, prior) }
        let child = try SpawnedChild.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "kill -TERM $$; echo survived"]
        )
        defer { child.cleanup() }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, child.reapIfExited() == nil { usleep(1_000) }

        XCTAssertFalse(String(decoding: child.readStdout(), as: UTF8.self).contains("survived"))
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

    func testEventSnapshotKeepsBatchDescriptorIdentityAfterChildCleanup() throws {
        let child = try SpawnedChild.spawn(executable: "/bin/sleep", arguments: ["10"])
        let snapshot = SpawnedChildEventSnapshot(child)
        let originalStdout = child.stdoutFD
        let originalStderr = child.stderrFD

        child.cleanup(graceMilliseconds: 20)

        XCTAssertTrue(snapshot.child === child)
        XCTAssertEqual(snapshot.stdoutFD, originalStdout)
        XCTAssertEqual(snapshot.stderrFD, originalStderr)
        XCTAssertEqual(snapshot.pid, child.pid)
        XCTAssertEqual(child.stdoutFD, -1)
        XCTAssertEqual(child.stderrFD, -1)
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
