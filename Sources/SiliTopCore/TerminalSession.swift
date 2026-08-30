import Darwin
import Foundation

public enum TerminalError: Error, Equatable, CustomStringConvertible {
    case notTTY
    case systemCall(String, Int32)

    public var description: String {
        switch self {
        case .notTTY:
            return "silitop requires an interactive terminal"
        case let .systemCall(name, code):
            return "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}

public enum DashboardInput {
    public static func shouldQuit<S: Sequence>(_ bytes: S) -> Bool where S.Element == UInt8 {
        bytes.contains { $0 == UInt8(ascii: "q") || $0 == UInt8(ascii: "Q") || $0 == 0x1B }
    }
}

public final class TerminalSession {
    public let inputFD: Int32
    public let outputFD: Int32

    private var originalAttributes: termios?
    private var originalInputFlags: Int32?
    private var originalOutputFlags: Int32?
    private var active = false

    public init(inputFD: Int32 = STDIN_FILENO, outputFD: Int32 = STDOUT_FILENO) {
        self.inputFD = inputFD
        self.outputFD = outputFD
    }

    deinit {
        restore()
    }

    public func begin() throws {
        guard !active else { return }
        guard isatty(inputFD) == 1, isatty(outputFD) == 1 else {
            throw TerminalError.notTTY
        }

        var attributes = termios()
        guard tcgetattr(inputFD, &attributes) == 0 else {
            throw TerminalError.systemCall("tcgetattr", errno)
        }
        let inputFlags = fcntl(inputFD, F_GETFL)
        guard inputFlags >= 0 else {
            throw TerminalError.systemCall("fcntl", errno)
        }
        let outputFlags = fcntl(outputFD, F_GETFL)
        guard outputFlags >= 0 else {
            throw TerminalError.systemCall("fcntl", errno)
        }

        var raw = attributes
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | IEXTEN)
        withUnsafeMutablePointer(to: &raw.c_cc) { tuple in
            tuple.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { controls in
                controls[Int(VMIN)] = 0
                controls[Int(VTIME)] = 0
            }
        }
        guard tcsetattr(inputFD, TCSAFLUSH, &raw) == 0 else {
            throw TerminalError.systemCall("tcsetattr", errno)
        }
        guard fcntl(inputFD, F_SETFL, inputFlags | O_NONBLOCK) == 0 else {
            let code = errno
            var restoreAttributes = attributes
            _ = tcsetattr(inputFD, TCSANOW, &restoreAttributes)
            throw TerminalError.systemCall("fcntl", code)
        }
        guard fcntl(outputFD, F_SETFL, outputFlags | O_NONBLOCK) == 0 else {
            let code = errno
            _ = fcntl(inputFD, F_SETFL, inputFlags)
            var restoreAttributes = attributes
            _ = tcsetattr(inputFD, TCSANOW, &restoreAttributes)
            throw TerminalError.systemCall("fcntl", code)
        }

        originalAttributes = attributes
        originalInputFlags = inputFlags
        originalOutputFlags = outputFlags
        active = true
        try write(Data("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J\u{1B}[H".utf8))
    }

    public func write(_ data: Data) throws {
        var offset = 0
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(20))
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while offset < data.count {
                let result = Darwin.write(outputFD, base.advanced(by: offset), data.count - offset)
                if result > 0 {
                    offset += result
                } else if result == -1, errno == EINTR {
                    continue
                } else if result == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    guard remaining > .zero else { return }
                    var descriptor = pollfd(fd: outputFD, events: Int16(POLLOUT), revents: 0)
                    let waitMilliseconds = min(5, max(1, Int(remaining.components.seconds * 1_000)
                        + Int(remaining.components.attoseconds / 1_000_000_000_000_000)))
                    let ready = Darwin.poll(&descriptor, 1, Int32(waitMilliseconds))
                    if ready == -1, errno == EINTR { continue }
                    if ready == -1 { throw TerminalError.systemCall("poll", errno) }
                } else {
                    throw TerminalError.systemCall("write", errno)
                }
            }
        }
    }

    public func restore() {
        guard active else { return }
        _ = try? write(Data("\u{1B}[?25h\u{1B}[?1049l".utf8))
        if var attributes = originalAttributes {
            // Restoration must not wait for a terminal emulator to drain its
            // output queue; that can deadlock cleanup after disconnect.
            _ = tcsetattr(inputFD, TCSANOW, &attributes)
        }
        if let flags = originalInputFlags {
            _ = fcntl(inputFD, F_SETFL, flags)
        }
        if let flags = originalOutputFlags {
            _ = fcntl(outputFD, F_SETFL, flags)
        }
        active = false
        originalAttributes = nil
        originalInputFlags = nil
        originalOutputFlags = nil
    }
}

public extension TerminalSize {
    static func read(from descriptor: Int32 = STDOUT_FILENO) -> TerminalSize? {
        var value = winsize()
        guard ioctl(descriptor, TIOCGWINSZ, &value) == 0,
              value.ws_row > 0,
              value.ws_col > 0 else {
            return nil
        }
        return TerminalSize(rows: Int(value.ws_row), columns: Int(value.ws_col))
    }
}
