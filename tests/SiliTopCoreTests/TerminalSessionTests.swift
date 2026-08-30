import Darwin
import Foundation
import XCTest
@testable import SiliTopCore

final class TerminalSessionTests: XCTestCase {
    func testDashboardQuitKeysPreserveQUppercaseAndEscape() {
        XCTAssertTrue(DashboardInput.shouldQuit([UInt8(ascii: "q")]))
        XCTAssertTrue(DashboardInput.shouldQuit([UInt8(ascii: "Q")]))
        XCTAssertTrue(DashboardInput.shouldQuit([0x1B]))
        XCTAssertFalse(DashboardInput.shouldQuit([UInt8(ascii: "x")]))
    }

    func testBeginUsesNoncanonicalNonblockingInputAndRestoreIsExact() throws {
        let pty = try makePTY()
        defer { Darwin.close(pty.master); Darwin.close(pty.slave) }
        var original = termios()
        XCTAssertEqual(tcgetattr(pty.slave, &original), 0)
        let originalFlags = fcntl(pty.slave, F_GETFL)
        let session = TerminalSession(inputFD: pty.slave, outputFD: pty.slave)

        try session.begin()
        var active = termios()
        XCTAssertEqual(tcgetattr(pty.slave, &active), 0)
        XCTAssertEqual(active.c_lflag & tcflag_t(ICANON), 0)
        XCTAssertEqual(active.c_lflag & tcflag_t(ECHO), 0)
        XCTAssertNotEqual(active.c_lflag & tcflag_t(ISIG), 0)
        XCTAssertNotEqual(fcntl(pty.slave, F_GETFL) & O_NONBLOCK, 0)

        session.restore()
        var restored = termios()
        XCTAssertEqual(tcgetattr(pty.slave, &restored), 0)
        XCTAssertEqual(restored.c_iflag, original.c_iflag)
        XCTAssertEqual(restored.c_oflag, original.c_oflag)
        XCTAssertEqual(restored.c_cflag, original.c_cflag)
        // The kernel may set PENDIN while re-enabling canonical input on a
        // pseudo-terminal; compare the user-controlled flags around it.
        XCTAssertEqual(restored.c_lflag & ~tcflag_t(PENDIN), original.c_lflag & ~tcflag_t(PENDIN))
        XCTAssertEqual(fcntl(pty.slave, F_GETFL) & O_NONBLOCK, originalFlags & O_NONBLOCK)
    }

    func testAlternateScreenAndCursorAreAlwaysUndoneIdempotently() throws {
        let pty = try makePTY()
        defer { Darwin.close(pty.master); Darwin.close(pty.slave) }
        _ = fcntl(pty.master, F_SETFL, fcntl(pty.master, F_GETFL) | O_NONBLOCK)
        let session = TerminalSession(inputFD: pty.slave, outputFD: pty.slave)

        try session.begin()
        usleep(5_000)
        let entered = readAll(pty.master)
        session.restore()
        session.restore()
        usleep(5_000)
        let output = String(decoding: entered + readAll(pty.master), as: UTF8.self)

        XCTAssertTrue(output.contains("\u{1B}[?1049h"))
        XCTAssertTrue(output.contains("\u{1B}[?25l"))
        XCTAssertTrue(output.contains("\u{1B}[?25h"))
        XCTAssertTrue(output.contains("\u{1B}[?1049l"))
        XCTAssertEqual(output.components(separatedBy: "\u{1B}[?1049l").count - 1, 1)
    }

    func testBackpressuredOutputReturnsWithoutBusySpinning() throws {
        let pty = try makePTY()
        defer { Darwin.close(pty.master); Darwin.close(pty.slave) }
        _ = fcntl(pty.master, F_SETFL, fcntl(pty.master, F_GETFL) | O_NONBLOCK)
        let session = TerminalSession(inputFD: pty.slave, outputFD: pty.slave)
        try session.begin()
        _ = readAll(pty.master)

        let started = ContinuousClock.now
        try session.write(Data(repeating: UInt8(ascii: "x"), count: 1_000_000))
        let elapsed = started.duration(to: .now)
        session.restore()
        usleep(5_000)
        let output = String(decoding: readAll(pty.master), as: UTF8.self)

        XCTAssertLessThan(elapsed, .milliseconds(100))
        XCTAssertTrue(output.contains("\u{1B}[?25h\u{1B}[?1049l"))
    }

    func testNonTTYIsRejectedBeforeMutation() {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { Darwin.close(descriptors[0]); Darwin.close(descriptors[1]) }

        XCTAssertThrowsError(try TerminalSession(
            inputFD: descriptors[0],
            outputFD: descriptors[1]
        ).begin()) { error in
            XCTAssertEqual(error as? TerminalError, .notTTY)
        }
    }

    func testTerminalSizeUsesWinsizeFromTTY() throws {
        let pty = try makePTY()
        defer { Darwin.close(pty.master); Darwin.close(pty.slave) }
        var size = winsize(ws_row: 42, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        XCTAssertEqual(ioctl(pty.slave, TIOCSWINSZ, &size), 0)

        XCTAssertEqual(TerminalSize.read(from: pty.slave), TerminalSize(rows: 42, columns: 120))
    }

    private func makePTY() throws -> (master: Int32, slave: Int32) {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return (master, slave)
    }

    private func readAll(_ descriptor: Int32) -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { output.append(buffer, count: count); continue }
            break
        }
        return output
    }
}
