import Darwin
import Foundation

public enum EventLoopError: Error, CustomStringConvertible {
    case systemCall(String, Int32)

    public var description: String {
        switch self {
        case let .systemCall(name, code):
            return "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}

public enum KqueueEvent: Equatable {
    case read(Int32)
    case readEOF(Int32)
    case processExit(pid_t)
    case timer(UInt)
    case signal(Int32)
    case error(identifier: UInt, code: Int32)
    case other(identifier: UInt, filter: Int16)
}

public final class Kqueue {
    public let descriptor: Int32
    private typealias SignalHandler = @convention(c) (Int32) -> Void
    private var priorSignalHandlers: [(Int32, SignalHandler?)] = []

    public init() throws {
        descriptor = Darwin.kqueue()
        guard descriptor >= 0 else {
            throw EventLoopError.systemCall("kqueue", errno)
        }
        let flags = fcntl(descriptor, F_GETFD)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) }
    }

    deinit {
        for (number, handler) in priorSignalHandlers.reversed() {
            _ = Darwin.signal(number, handler)
        }
        Darwin.close(descriptor)
    }

    public func watchRead(_ fileDescriptor: Int32) throws {
        try add(
            identifier: UInt(fileDescriptor),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD | EV_ENABLE),
            filterFlags: 0,
            data: 0
        )
    }

    public func watchProcess(_ pid: pid_t) throws {
        try add(
            identifier: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            filterFlags: UInt32(NOTE_EXIT),
            data: 0
        )
    }

    public func watchTimer(identifier: UInt, milliseconds: Int, repeating: Bool) throws {
        var flags = UInt16(EV_ADD | EV_ENABLE)
        flags |= repeating ? UInt16(EV_CLEAR) : UInt16(EV_ONESHOT)
        try add(
            identifier: identifier,
            filter: Int16(EVFILT_TIMER),
            flags: flags,
            filterFlags: UInt32(NOTE_USECONDS),
            data: max(1, milliseconds) * 1_000
        )
    }

    public func watchSignal(_ number: Int32) throws {
        guard !priorSignalHandlers.contains(where: { $0.0 == number }) else { return }
        let prior = Darwin.signal(number, SIG_IGN)
        do {
            try add(
                identifier: UInt(number),
                filter: Int16(EVFILT_SIGNAL),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
                filterFlags: 0,
                data: 0
            )
            priorSignalHandlers.append((number, prior))
        } catch {
            _ = Darwin.signal(number, prior)
            throw error
        }
    }

    public func wait(maxEvents: Int, timeoutMilliseconds: Int? = nil) throws -> [KqueueEvent] {
        var storage = [kevent64_s](repeating: kevent64_s(), count: max(1, maxEvents))
        var timeout = timespec()
        let count: Int32
        if let timeoutMilliseconds {
            timeout.tv_sec = timeoutMilliseconds / 1_000
            timeout.tv_nsec = (timeoutMilliseconds % 1_000) * 1_000_000
            count = kevent64(descriptor, nil, 0, &storage, Int32(storage.count), 0, &timeout)
        } else {
            count = kevent64(descriptor, nil, 0, &storage, Int32(storage.count), 0, nil)
        }
        if count == -1 {
            if errno == EINTR { return [] }
            throw EventLoopError.systemCall("kevent", errno)
        }
        return storage.prefix(Int(count)).map(Self.convert)
    }

    private func add(
        identifier: UInt,
        filter: Int16,
        flags: UInt16,
        filterFlags: UInt32,
        data: Int
    ) throws {
        var change = kevent64_s()
        change.ident = UInt64(identifier)
        change.filter = filter
        change.flags = flags
        change.fflags = filterFlags
        change.data = Int64(data)
        let result = kevent64(descriptor, &change, 1, nil, 0, 0, nil)
        guard result == 0 else {
            throw EventLoopError.systemCall("kevent registration", errno)
        }
    }

    private static func convert(_ event: kevent64_s) -> KqueueEvent {
        if event.flags & UInt16(EV_ERROR) != 0, event.data != 0 {
            return .error(identifier: UInt(event.ident), code: Int32(event.data))
        }
        switch event.filter {
        case Int16(EVFILT_READ):
            if event.flags & UInt16(EV_EOF) != 0 {
                return .readEOF(Int32(event.ident))
            }
            return .read(Int32(event.ident))
        case Int16(EVFILT_PROC):
            return .processExit(pid_t(event.ident))
        case Int16(EVFILT_TIMER):
            return .timer(UInt(event.ident))
        case Int16(EVFILT_SIGNAL):
            return .signal(Int32(event.ident))
        default:
            return .other(identifier: UInt(event.ident), filter: event.filter)
        }
    }
}
