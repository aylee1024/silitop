import Darwin
import Foundation
import XCTest
@testable import SiliTopCore

final class DashboardApplicationTests: XCTestCase {
    func testEventLoopRendersSampleAcceptsQuitAndRestoresPTY() throws {
        let pty = try makePTY(rows: 40, columns: 100)
        defer { Darwin.close(pty.master); Darwin.close(pty.slave) }
        _ = fcntl(pty.master, F_SETFL, fcntl(pty.master, F_GETFL) | O_NONBLOCK)
        var original = termios()
        XCTAssertEqual(tcgetattr(pty.slave, &original), 0)
        let fixture = try writeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let command = ChildCommand(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import os,time;d=open(r'\(fixture.path)','rb').read();os.write(1,d+b'\\0');time.sleep(10)"]
        )
        let application = DashboardApplication(
            options: CLIOptions(),
            terminal: TerminalSession(inputFD: pty.slave, outputFD: pty.slave),
            runtime: DashboardRuntimeConfiguration(
                samplerCommands: [command],
                profilerCommand: nil,
                watchesSignals: false,
                stallTimeoutOverride: 1
            )
        )
        let finished = expectation(description: "dashboard quits")
        let result = LockedResult()

        DispatchQueue.global().async {
            do { try application.run() } catch { result.error = error }
            finished.fulfill()
        }
        var captured = waitForOutput(pty.master, containing: "Disk I/O", timeout: 3)
        var quit = UInt8(ascii: "q")
        XCTAssertEqual(Darwin.write(pty.master, &quit, 1), 1)
        wait(for: [finished], timeout: 2)

        XCTAssertNil(result.error)
        usleep(5_000)
        captured.append(readAll(pty.master))
        let output = String(decoding: captured, as: UTF8.self)
        XCTAssertTrue(output.contains("Waiting for powermetrics"))
        XCTAssertTrue(output.contains("Disk I/O"), "Captured PTY output:\n\(output)")
        XCTAssertTrue(output.contains("\u{1B}[?1049l"))
        var restored = termios()
        XCTAssertEqual(tcgetattr(pty.slave, &restored), 0)
        XCTAssertEqual(restored.c_lflag & ~tcflag_t(PENDIN), original.c_lflag & ~tcflag_t(PENDIN))
    }

    func testFullSamplerEarlyExitRetriesEssentialCommandOnce() throws {
        let pty = try makePTY(rows: 40, columns: 100)
        defer { Darwin.close(pty.master); Darwin.close(pty.slave) }
        _ = fcntl(pty.master, F_SETFL, fcntl(pty.master, F_GETFL) | O_NONBLOCK)
        let fixture = try writeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let working = ChildCommand(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import os,time;d=open(r'\(fixture.path)','rb').read();os.write(1,d+b'\\0');time.sleep(10)"]
        )
        let application = DashboardApplication(
            options: CLIOptions(),
            terminal: TerminalSession(inputFD: pty.slave, outputFD: pty.slave),
            runtime: DashboardRuntimeConfiguration(
                samplerCommands: [ChildCommand(executable: "/usr/bin/false", arguments: []), working],
                profilerCommand: nil,
                watchesSignals: false,
                stallTimeoutOverride: 1
            )
        )
        let finished = expectation(description: "fallback then quit")
        let result = LockedResult()

        DispatchQueue.global().async {
            do { try application.run() } catch { result.error = error }
            finished.fulfill()
        }
        var captured = waitForOutput(pty.master, containing: "CPU", timeout: 3)
        var quit = UInt8(ascii: "q")
        _ = Darwin.write(pty.master, &quit, 1)
        wait(for: [finished], timeout: 2)

        XCTAssertNil(result.error)
        captured.append(readAll(pty.master))
        let output = String(decoding: captured, as: UTF8.self)
        XCTAssertTrue(output.contains("CPU"), "Captured PTY output:\n\(output)")
    }

    func testNoValidRecordBeforeDeadlineIsFatalAndRestoresTerminal() throws {
        let pty = try makePTY(rows: 40, columns: 100)
        defer { Darwin.close(pty.master); Darwin.close(pty.slave) }
        let application = DashboardApplication(
            options: CLIOptions(),
            terminal: TerminalSession(inputFD: pty.slave, outputFD: pty.slave),
            runtime: DashboardRuntimeConfiguration(
                samplerCommands: [ChildCommand(executable: "/bin/sleep", arguments: ["10"])],
                profilerCommand: nil,
                watchesSignals: false,
                stallTimeoutOverride: 0.05
            )
        )

        XCTAssertThrowsError(try application.run()) { error in
            guard case DashboardRuntimeError.stalled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        var restored = termios()
        XCTAssertEqual(tcgetattr(pty.slave, &restored), 0)
        XCTAssertNotEqual(restored.c_lflag & tcflag_t(ICANON), 0)
    }

    func testQuitRestoresTerminalWithinOneHundredMilliseconds() throws {
        let pty = try makePTY(rows: 40, columns: 100)
        defer { Darwin.close(pty.master); Darwin.close(pty.slave) }
        _ = fcntl(pty.master, F_SETFL, fcntl(pty.master, F_GETFL) | O_NONBLOCK)
        let fixture = try writeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let application = makeFixtureApplication(pty: pty, fixture: fixture)
        let finished = expectation(description: "fast quit")
        let result = LockedResult()

        DispatchQueue.global().async {
            do { try application.run() } catch { result.error = error }
            finished.fulfill()
        }
        _ = waitForOutput(pty.master, containing: "Disk I/O", timeout: 3)
        var quit = UInt8(ascii: "q")
        let started = ContinuousClock.now
        XCTAssertEqual(Darwin.write(pty.master, &quit, 1), 1)
        wait(for: [finished], timeout: 1)
        let elapsed = started.duration(to: .now)

        XCTAssertNil(result.error)
        XCTAssertLessThan(elapsed, .milliseconds(100))
        var restored = termios()
        XCTAssertEqual(tcgetattr(pty.slave, &restored), 0)
        XCTAssertNotEqual(restored.c_lflag & tcflag_t(ICANON), 0)
    }

    func testSamplerDeathAfterValidRecordIsFatalAndRestoresTerminal() throws {
        let pty = try makePTY(rows: 40, columns: 100)
        defer { Darwin.close(pty.master); Darwin.close(pty.slave) }
        let fixture = try writeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let command = ChildCommand(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import os;d=open(r'\(fixture.path)','rb').read();os.write(1,d+b'\\0')"]
        )
        let application = DashboardApplication(
            options: CLIOptions(),
            terminal: TerminalSession(inputFD: pty.slave, outputFD: pty.slave),
            runtime: DashboardRuntimeConfiguration(
                samplerCommands: [command], profilerCommand: nil,
                watchesSignals: false, stallTimeoutOverride: 1
            )
        )

        XCTAssertThrowsError(try application.run()) { error in
            guard case DashboardRuntimeError.collectorExited = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        var restored = termios()
        XCTAssertEqual(tcgetattr(pty.slave, &restored), 0)
        XCTAssertNotEqual(restored.c_lflag & tcflag_t(ICANON), 0)
    }

    func testTwoDashboardInstancesUseIndependentChildrenAndTerminals() throws {
        let firstPTY = try makePTY(rows: 40, columns: 100)
        let secondPTY = try makePTY(rows: 40, columns: 100)
        defer {
            for descriptor in [firstPTY.master, firstPTY.slave, secondPTY.master, secondPTY.slave] {
                Darwin.close(descriptor)
            }
        }
        for master in [firstPTY.master, secondPTY.master] {
            _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        }
        let fixture = try writeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let first = makeFixtureApplication(pty: firstPTY, fixture: fixture)
        let second = makeFixtureApplication(pty: secondPTY, fixture: fixture)
        let firstFinished = expectation(description: "first quit")
        let secondFinished = expectation(description: "second quit")
        let firstResult = LockedResult()
        let secondResult = LockedResult()

        DispatchQueue.global().async {
            do { try first.run() } catch { firstResult.error = error }
            firstFinished.fulfill()
        }
        DispatchQueue.global().async {
            do { try second.run() } catch { secondResult.error = error }
            secondFinished.fulfill()
        }
        let firstOutput = waitForOutput(firstPTY.master, containing: "Disk I/O", timeout: 3)
        let secondOutput = waitForOutput(secondPTY.master, containing: "Disk I/O", timeout: 3)
        XCTAssertTrue(String(decoding: firstOutput, as: UTF8.self).contains("Disk I/O"))
        XCTAssertTrue(String(decoding: secondOutput, as: UTF8.self).contains("Disk I/O"))
        var quit = UInt8(ascii: "q")
        XCTAssertEqual(Darwin.write(firstPTY.master, &quit, 1), 1)
        XCTAssertEqual(Darwin.write(secondPTY.master, &quit, 1), 1)
        wait(for: [firstFinished, secondFinished], timeout: 2)

        XCTAssertNil(firstResult.error)
        XCTAssertNil(secondResult.error)
    }

    func testHungStartupProfilerIsTerminatedWithoutStoppingDashboard() throws {
        let pty = try makePTY(rows: 40, columns: 100)
        defer { Darwin.close(pty.master); Darwin.close(pty.slave) }
        _ = fcntl(pty.master, F_SETFL, fcntl(pty.master, F_GETFL) | O_NONBLOCK)
        let fixture = try writeFixture()
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: pidFile)
        }
        let application = DashboardApplication(
            options: CLIOptions(),
            terminal: TerminalSession(inputFD: pty.slave, outputFD: pty.slave),
            runtime: DashboardRuntimeConfiguration(
                samplerCommands: [fixtureCommand(fixture)],
                profilerCommand: ChildCommand(
                    executable: "/usr/bin/python3",
                    arguments: ["-c", "import os,time;open(r'\(pidFile.path)','w').write(str(os.getpid()));time.sleep(10)"]
                ),
                watchesSignals: false,
                stallTimeoutOverride: 1,
                profilerTimeoutOverride: 0.05
            )
        )
        let finished = expectation(description: "dashboard remains responsive")
        let result = LockedResult()
        DispatchQueue.global().async {
            do { try application.run() } catch { result.error = error }
            finished.fulfill()
        }
        _ = waitForOutput(pty.master, containing: "Disk I/O", timeout: 3)
        let pidDeadline = Date().addingTimeInterval(1)
        while Date() < pidDeadline, !FileManager.default.fileExists(atPath: pidFile.path) {
            usleep(1_000)
        }
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let profilerPID = try XCTUnwrap(pid_t(pidText))
        let exitDeadline = Date().addingTimeInterval(1)
        while Date() < exitDeadline, Darwin.kill(profilerPID, 0) == 0 {
            usleep(1_000)
        }
        XCTAssertEqual(Darwin.kill(profilerPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)

        var quit = UInt8(ascii: "q")
        XCTAssertEqual(Darwin.write(pty.master, &quit, 1), 1)
        wait(for: [finished], timeout: 1)
        XCTAssertNil(result.error)
    }

    func testSIGTERMExitsNormallyAndRestoresTerminal() throws {
        let pty = try makePTY(rows: 40, columns: 100)
        defer { Darwin.close(pty.master); Darwin.close(pty.slave) }
        _ = fcntl(pty.master, F_SETFL, fcntl(pty.master, F_GETFL) | O_NONBLOCK)
        let fixture = try writeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let application = DashboardApplication(
            options: CLIOptions(),
            terminal: TerminalSession(inputFD: pty.slave, outputFD: pty.slave),
            runtime: DashboardRuntimeConfiguration(
                samplerCommands: [fixtureCommand(fixture)], profilerCommand: nil,
                watchesSignals: true, stallTimeoutOverride: 1
            )
        )
        let finished = expectation(description: "signal exits")
        let result = LockedResult()

        DispatchQueue.global().async {
            do { try application.run() } catch { result.error = error }
            finished.fulfill()
        }
        _ = waitForOutput(pty.master, containing: "Disk I/O", timeout: 3)
        XCTAssertEqual(Darwin.kill(getpid(), SIGTERM), 0)
        wait(for: [finished], timeout: 1)

        XCTAssertNil(result.error)
        var restored = termios()
        XCTAssertEqual(tcgetattr(pty.slave, &restored), 0)
        XCTAssertNotEqual(restored.c_lflag & tcflag_t(ICANON), 0)
    }

    private func writeFixture() throws -> URL {
        let value: [String: Any] = [
            "timestamp": Date(timeIntervalSince1970: 1_000),
            "processor": [
                "clusters": [[
                    "name": "P-Cluster",
                    "freq_hz": 3_000_000_000.0,
                    "cpus": [["cpu": 0, "idle_ratio": 0.5, "freq_hz": 3_000_000_000.0]],
                ]],
                "cpu_energy": 1_000.0,
                "gpu_energy": 500.0,
                "ane_energy": 100.0,
                "combined_power": 5_000.0,
            ],
            "gpu": ["idle_ratio": 0.5, "freq_hz": 1_000.0],
            "thermal_pressure": "Nominal",
            "network": ["ibyte_rate": 1_024.0, "obyte_rate": 2_048.0],
            "disk": ["rbytes_per_s": 4_096.0, "wbytes_per_s": 8_192.0],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".plist")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func fixtureCommand(_ fixture: URL) -> ChildCommand {
        ChildCommand(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import os,time;d=open(r'\(fixture.path)','rb').read();os.write(1,d+b'\\0');time.sleep(10)"]
        )
    }

    private func makeFixtureApplication(
        pty: (master: Int32, slave: Int32),
        fixture: URL
    ) -> DashboardApplication {
        DashboardApplication(
            options: CLIOptions(),
            terminal: TerminalSession(inputFD: pty.slave, outputFD: pty.slave),
            runtime: DashboardRuntimeConfiguration(
                samplerCommands: [fixtureCommand(fixture)], profilerCommand: nil,
                watchesSignals: false, stallTimeoutOverride: 1
            )
        )
    }

    private func makePTY(rows: UInt16, columns: UInt16) throws -> (master: Int32, slave: Int32) {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        XCTAssertEqual(ioctl(slave, TIOCSWINSZ, &size), 0)
        return (master, slave)
    }

    private func readAll(_ descriptor: Int32) -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { output.append(buffer, count: count); continue }
            break
        }
        return output
    }

    private func waitForOutput(_ descriptor: Int32, containing needle: String, timeout: TimeInterval) -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        while Date() < deadline {
            output.append(readAll(descriptor))
            if String(decoding: output, as: UTF8.self).contains(needle) { break }
            usleep(1_000)
        }
        return output
    }
}

private final class LockedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        get { lock.lock(); defer { lock.unlock() }; return storedError }
        set { lock.lock(); defer { lock.unlock() }; storedError = newValue }
    }
}
