import Darwin
import Foundation

public struct ChildSpawnError: Error, CustomStringConvertible {
    public let executable: String
    public let code: Int32

    public var description: String {
        "failed to launch \(executable): \(String(cString: strerror(code)))"
    }
}

public final class SpawnedChild {
    public let pid: pid_t
    public private(set) var stdoutFD: Int32
    public private(set) var stderrFD: Int32

    private var reaped = false
    private var status: Int32?

    private init(pid: pid_t, stdoutFD: Int32, stderrFD: Int32) {
        self.pid = pid
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
    }

    deinit {
        cleanup()
    }

    public static func spawn(executable: String, arguments: [String]) throws -> SpawnedChild {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0 else {
            throw ChildSpawnError(executable: executable, code: errno)
        }
        guard pipe(&stderrPipe) == 0 else {
            let code = errno
            Darwin.close(stdoutPipe[0])
            Darwin.close(stdoutPipe[1])
            throw ChildSpawnError(executable: executable, code: code)
        }

        var actions: posix_spawn_file_actions_t? = nil
        var initializedActions = false
        var attributes: posix_spawnattr_t? = nil
        var initializedAttributes = false
        var childPID: pid_t = 0
        var spawnCode: Int32 = EINVAL
        let values = [executable] + arguments
        var argv: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        argv.append(nil)

        defer {
            argv.forEach { free($0) }
            if initializedActions { posix_spawn_file_actions_destroy(&actions) }
            if initializedAttributes { posix_spawnattr_destroy(&attributes) }
        }

        let initCode = posix_spawn_file_actions_init(&actions)
        guard initCode == 0 else {
            closePipe(stdoutPipe)
            closePipe(stderrPipe)
            throw ChildSpawnError(executable: executable, code: initCode)
        }
        initializedActions = true

        let attributeCode = posix_spawnattr_init(&attributes)
        guard attributeCode == 0 else {
            closePipe(stdoutPipe)
            closePipe(stderrPipe)
            throw ChildSpawnError(executable: executable, code: attributeCode)
        }
        initializedAttributes = true
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for number in [SIGINT, SIGTERM, SIGHUP, SIGWINCH, SIGQUIT, SIGTSTP] {
            sigaddset(&defaultSignals, number)
        }
        let signalCode = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        let attributeFlags = Int16(POSIX_SPAWN_SETSIGDEF)
        let flagsCode = posix_spawnattr_setflags(&attributes, attributeFlags)
        guard signalCode == 0, flagsCode == 0 else {
            closePipe(stdoutPipe)
            closePipe(stderrPipe)
            throw ChildSpawnError(
                executable: executable,
                code: signalCode == 0 ? flagsCode : signalCode
            )
        }

        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[1])
        posix_spawn_file_actions_addclose(&actions, stderrPipe[0])
        posix_spawn_file_actions_addclose(&actions, stderrPipe[1])

        spawnCode = executable.withCString { path in
            argv.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(&childPID, path, &actions, &attributes, buffer.baseAddress, environ)
            }
        }

        Darwin.close(stdoutPipe[1])
        Darwin.close(stderrPipe[1])
        guard spawnCode == 0 else {
            Darwin.close(stdoutPipe[0])
            Darwin.close(stderrPipe[0])
            throw ChildSpawnError(executable: executable, code: spawnCode)
        }

        setNonblockingAndCloseOnExec(stdoutPipe[0])
        setNonblockingAndCloseOnExec(stderrPipe[0])
        return SpawnedChild(pid: childPID, stdoutFD: stdoutPipe[0], stderrFD: stderrPipe[0])
    }

    public func readStdout(maximumBytes: Int = 64 * 1_024) -> Data {
        readAvailable(from: stdoutFD, maximumBytes: maximumBytes)
    }

    public func readStderr(maximumBytes: Int = 64 * 1_024) -> Data {
        readAvailable(from: stderrFD, maximumBytes: maximumBytes)
    }

    @discardableResult
    public func reapIfExited() -> Int32? {
        if reaped { return status }
        var rawStatus: Int32 = 0
        let result = waitpid(pid, &rawStatus, WNOHANG)
        if result == pid {
            reaped = true
            status = rawStatus
            return rawStatus
        }
        if result == -1, errno == ECHILD {
            reaped = true
        }
        return nil
    }

    public func cleanup(graceMilliseconds: Int = 75) {
        if !reaped {
            _ = Darwin.kill(pid, SIGTERM)
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(max(0, graceMilliseconds)))
            while ContinuousClock.now < deadline, reapIfExited() == nil {
                usleep(1_000)
            }
            if !reaped {
                _ = Darwin.kill(pid, SIGKILL)
                var rawStatus: Int32 = 0
                while waitpid(pid, &rawStatus, 0) == -1, errno == EINTR {}
                reaped = true
                status = rawStatus
            }
        }
        closeDescriptors()
    }

    private func closeDescriptors() {
        if stdoutFD >= 0 {
            Darwin.close(stdoutFD)
            stdoutFD = -1
        }
        if stderrFD >= 0 {
            Darwin.close(stderrFD)
            stderrFD = -1
        }
    }
}

private func closePipe(_ descriptors: [Int32]) {
    for descriptor in descriptors where descriptor >= 0 {
        Darwin.close(descriptor)
    }
}

private func setNonblockingAndCloseOnExec(_ descriptor: Int32) {
    let statusFlags = fcntl(descriptor, F_GETFL)
    if statusFlags >= 0 { _ = fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) }
    let descriptorFlags = fcntl(descriptor, F_GETFD)
    if descriptorFlags >= 0 { _ = fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) }
}

private func readAvailable(from descriptor: Int32, maximumBytes: Int) -> Data {
    guard descriptor >= 0, maximumBytes > 0 else { return Data() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: min(8 * 1_024, maximumBytes))
    while result.count < maximumBytes {
        let requested = min(buffer.count, maximumBytes - result.count)
        let count = Darwin.read(descriptor, &buffer, requested)
        if count > 0 {
            result.append(buffer, count: count)
            continue
        }
        if count == -1, errno == EINTR { continue }
        break
    }
    return result
}
