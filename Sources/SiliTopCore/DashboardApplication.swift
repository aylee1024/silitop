import Darwin
import Foundation

public struct DashboardRuntimeConfiguration: Sendable {
    public let samplerCommands: [ChildCommand]
    public let profilerCommand: ChildCommand?
    public let watchesSignals: Bool
    public let stallTimeoutOverride: TimeInterval?
    public let profilerTimeoutOverride: TimeInterval?
    public let fastFailureLimit: Int
    public let fastFailureWindow: TimeInterval

    public init(
        samplerCommands: [ChildCommand],
        profilerCommand: ChildCommand?,
        watchesSignals: Bool = true,
        stallTimeoutOverride: TimeInterval? = nil,
        profilerTimeoutOverride: TimeInterval? = nil,
        fastFailureLimit: Int = 3,
        fastFailureWindow: TimeInterval = 1
    ) {
        self.samplerCommands = samplerCommands
        self.profilerCommand = profilerCommand
        self.watchesSignals = watchesSignals
        self.stallTimeoutOverride = stallTimeoutOverride
        self.profilerTimeoutOverride = profilerTimeoutOverride
        self.fastFailureLimit = max(1, fastFailureLimit)
        self.fastFailureWindow = fastFailureWindow
    }

    public static func production(options: CLIOptions) -> DashboardRuntimeConfiguration {
        DashboardRuntimeConfiguration(
            samplerCommands: [
                PowerMetricsCommand(intervalSeconds: options.intervalSeconds, samplerSet: .full).childCommand,
                PowerMetricsCommand(intervalSeconds: options.intervalSeconds, samplerSet: .essential).childCommand,
            ],
            profilerCommand: nil
        )
    }
}

public enum DashboardRuntimeError: Error, CustomStringConvertible {
    case noSamplerCommands
    case collectorLaunch(String)
    case collectorExited(String)
    case stalled(TimeInterval, String)

    public var description: String {
        switch self {
        case .noSamplerCommands:
            return "no powermetrics command configured"
        case let .collectorLaunch(message):
            return "powermetrics failed to start: \(message)"
        case let .collectorExited(message):
            return "powermetrics exited unexpectedly\(message.isEmpty ? "" : ": \(message)")"
        case let .stalled(seconds, message):
            return "powermetrics produced no valid sample for \(String(format: "%.1f", seconds))s\(message.isEmpty ? "" : ": \(message)")"
        }
    }
}

public final class DashboardApplication: @unchecked Sendable {
    private static let stallTimerIdentifier: UInt = 1

    private let options: CLIOptions
    private let terminal: TerminalSession
    private let runtime: DashboardRuntimeConfiguration

    public init(
        options: CLIOptions,
        terminal: TerminalSession = TerminalSession(),
        runtime: DashboardRuntimeConfiguration? = nil
    ) {
        self.options = options
        self.terminal = terminal
        self.runtime = runtime ?? .production(options: options)
    }

    public func run() throws {
        guard !runtime.samplerCommands.isEmpty else {
            throw DashboardRuntimeError.noSamplerCommands
        }

        try terminal.begin()
        var sampler: SpawnedChild?
        var profiler: SpawnedChild?
        defer {
            profiler?.cleanup()
            sampler?.cleanup()
            terminal.restore()
        }

        let queue = try Kqueue()
        try queue.watchRead(terminal.inputFD)
        try queue.watchTimer(identifier: Self.stallTimerIdentifier, milliseconds: 100, repeating: true)
        if runtime.watchesSignals {
            for number in [SIGWINCH, SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
                try queue.watchSignal(number)
            }
        }

        var topology = TopologyDetector(
            sysctl: SystemSysctl.string,
            integerSysctl: SystemSysctl.uint64,
            gpuCoreCount: GPUCoreCountReader.read
        ).detect()
        var controller = DashboardStateController(
            topology: topology,
            intervalSeconds: options.intervalSeconds,
            averageSeconds: options.averageSeconds
        )
        var decoder = PowerMetricsDecoder(topology: topology)
        var framer = NULRecordFramer()
        let memoryCollector = HostMemoryCollector()
        let temperatureCollector = HIDTemperatureCollector()
        let fanCollector = AppleSMCFanCollector()
        let renderer = DashboardRenderer(ansi: true, colorScheme: options.colorScheme)
        var lastSnapshot: DashboardSnapshot?
        var profilerOutput = Data()
        var profilerStartedAt: ContinuousClock.Instant?
        var stderrTail = ByteTail(capacity: 8 * 1_024)
        var samplerIndex = 0
        var validRecordCount = 0
        var timestampGate = SampleTimestampGate()
        var validCountAtLaunch = 0
        var lastValidRecordAt = ContinuousClock.now
        var samplerLaunchedAt = ContinuousClock.now
        var fastFailures = 0
        let stallTimeout = runtime.stallTimeoutOverride
            ?? PowerMetricsCommand.stallTimeout(intervalSeconds: options.intervalSeconds)
        let profilerTimeout = runtime.profilerTimeoutOverride ?? 5

        func terminalSize() -> TerminalSize {
            TerminalSize.read(from: terminal.outputFD) ?? TerminalSize(rows: 24, columns: 80)
        }

        func drawWaiting() throws {
            let size = terminalSize()
            let chip = topology.name.map { " — \($0)" } ?? ""
            let width = max(1, size.columns)
            var lines: [String]
            if size.rows < 10 || size.columns < 40 {
                lines = ["Terminal too small — resize to at least 40×10"]
            } else {
                lines = ["silitop\(chip)", "", "Waiting for powermetrics…", "", "q: quit"]
            }
            let body = lines.prefix(max(1, size.rows))
                .map { DisplayWidth.fit($0, to: width) }
                .joined(separator: "\n") + "\n"
            try terminal.write(Data(("\u{1B}[H" + body + "\u{1B}[J").utf8))
        }

        func redraw() throws {
            if let lastSnapshot {
                try terminal.write(renderer.render(
                    snapshot: lastSnapshot,
                    histories: controller.histories,
                    size: terminalSize()
                ))
            } else {
                try drawWaiting()
            }
        }

        func processSamplerData(_ bytes: Data) throws {
            guard !bytes.isEmpty else { return }
            for record in framer.push(bytes) {
                guard let reading = decoder.decode(plistRecord: record) else { continue }
                guard timestampGate.shouldAccept(reading.timestamp) else { continue }
                let now = Date()
                let memory: NativeCollectorResult<MemoryReading> = memoryCollector.read().map {
                    .value($0)
                } ?? .unavailable(reason: "host statistics failed")
                let snapshot = controller.accept(
                    reading,
                    memory: memory,
                    temperatures: temperatureCollector.read(),
                    fans: fanCollector.read(),
                    at: now
                )
                lastSnapshot = snapshot
                lastValidRecordAt = .now
                validRecordCount += 1
                try redraw()
            }
        }

        func register(_ child: SpawnedChild) throws {
            try queue.watchRead(child.stdoutFD)
            try queue.watchRead(child.stderrFD)
            try queue.watchProcess(child.pid)
        }

        func drainSamplerOutput(_ child: SpawnedChild) throws {
            while true {
                let bytes = child.readStdout()
                guard !bytes.isEmpty else { return }
                try processSamplerData(bytes)
            }
        }

        func drainStderr(_ child: SpawnedChild) {
            while true {
                let bytes = child.readStderr()
                guard !bytes.isEmpty else { return }
                stderrTail.append(bytes)
            }
        }

        func drainProfilerOutput(_ child: SpawnedChild) {
            while true {
                let bytes = child.readStdout()
                guard !bytes.isEmpty else { return }
                if profilerOutput.count < 8 * 1_024 * 1_024 {
                    let remaining = 8 * 1_024 * 1_024 - profilerOutput.count
                    profilerOutput.append(bytes.prefix(remaining))
                }
            }
        }

        func launchSampler(at index: Int) throws -> SpawnedChild {
            let command = runtime.samplerCommands[index]
            do {
                let child = try SpawnedChild.spawn(
                    executable: command.executable,
                    arguments: command.arguments
                )
                try register(child)
                return child
            } catch {
                throw DashboardRuntimeError.collectorLaunch(String(describing: error))
            }
        }

        func relaunchWorkingSampler() throws {
            framer = NULRecordFramer()
            stderrTail = ByteTail(capacity: 8 * 1_024)
            sampler = try launchSampler(at: samplerIndex)
            samplerLaunchedAt = .now
            validCountAtLaunch = validRecordCount
            lastValidRecordAt = .now
        }

        try drawWaiting()
        sampler = try launchSampler(at: samplerIndex)
        samplerLaunchedAt = .now
        validCountAtLaunch = validRecordCount
        lastValidRecordAt = .now

        if let command = runtime.profilerCommand,
           let child = try? SpawnedChild.spawn(executable: command.executable, arguments: command.arguments) {
            profiler = child
            profilerStartedAt = .now
            try register(child)
        }

        while true {
            let events = try queue.wait(maxEvents: 16)
            let samplerAtWait = sampler.map(SpawnedChildEventSnapshot.init)
            let profilerAtWait = profiler.map(SpawnedChildEventSnapshot.init)
            for event in events {
                switch event {
                case let .read(descriptor) where descriptor == terminal.inputFD:
                    var buffer = [UInt8](repeating: 0, count: 64)
                    while true {
                        let count = Darwin.read(descriptor, &buffer, buffer.count)
                        if count > 0 {
                            if DashboardInput.shouldQuit(buffer.prefix(count)) {
                                return
                            }
                            continue
                        }
                        if count == -1, errno == EINTR { continue }
                        break
                    }

                case let .read(descriptor) where descriptor == samplerAtWait?.stdoutFD:
                    try processSamplerData(samplerAtWait?.child.readStdout() ?? Data())

                case let .read(descriptor) where descriptor == samplerAtWait?.stderrFD:
                    stderrTail.append(samplerAtWait?.child.readStderr() ?? Data())

                case let .read(descriptor) where descriptor == profilerAtWait?.stdoutFD:
                    let bytes = profilerAtWait?.child.readStdout() ?? Data()
                    if profilerOutput.count + bytes.count <= 8 * 1_024 * 1_024 {
                        profilerOutput.append(bytes)
                    }

                case let .read(descriptor) where descriptor == profilerAtWait?.stderrFD:
                    _ = profilerAtWait?.child.readStderr()

                case let .readEOF(descriptor) where descriptor == terminal.inputFD:
                    return

                case let .readEOF(descriptor) where descriptor == samplerAtWait?.stdoutFD:
                    if let current = samplerAtWait?.child {
                        try drainSamplerOutput(current)
                        current.closeStdout()
                    }

                case let .readEOF(descriptor) where descriptor == samplerAtWait?.stderrFD:
                    if let current = samplerAtWait?.child {
                        drainStderr(current)
                        current.closeStderr()
                    }

                case let .readEOF(descriptor) where descriptor == profilerAtWait?.stdoutFD:
                    if let current = profilerAtWait?.child {
                        drainProfilerOutput(current)
                        current.closeStdout()
                    }

                case let .readEOF(descriptor) where descriptor == profilerAtWait?.stderrFD:
                    if let current = profilerAtWait?.child {
                        while !current.readStderr().isEmpty {}
                        current.closeStderr()
                    }

                case let .processExit(pid) where pid == samplerAtWait?.pid:
                    if let current = samplerAtWait?.child {
                        try drainSamplerOutput(current)
                        drainStderr(current)
                        _ = current.reapIfExited()
                        current.cleanup()
                    }
                    sampler = nil
                    let producedThisLife = validRecordCount > validCountAtLaunch
                    let age = durationSeconds(samplerLaunchedAt.duration(to: .now))
                    // A life that already produced a sample is healthy, even when the
                    // child then exits. Only an immediate exit with no new sample
                    // counts toward the cap, so one bad reading cannot end the
                    // session and a launch that fails instantly cannot spin.
                    if validRecordCount == 0 && samplerIndex + 1 < runtime.samplerCommands.count {
                        samplerIndex += 1
                        fastFailures = 0
                        try relaunchWorkingSampler()
                    } else if validRecordCount == 0 {
                        throw DashboardRuntimeError.collectorExited(lastDiagnostic(stderrTail.string))
                    } else if !producedThisLife && age < runtime.fastFailureWindow {
                        fastFailures += 1
                        if fastFailures >= runtime.fastFailureLimit {
                            throw DashboardRuntimeError.collectorExited(lastDiagnostic(stderrTail.string))
                        }
                        try relaunchWorkingSampler()
                    } else {
                        fastFailures = 0
                        try relaunchWorkingSampler()
                    }

                case let .processExit(pid) where pid == profilerAtWait?.pid:
                    if let current = profilerAtWait?.child {
                        drainProfilerOutput(current)
                        while !current.readStderr().isEmpty {}
                        _ = current.reapIfExited()
                        current.cleanup()
                    }
                    profiler = nil
                    profilerStartedAt = nil
                    let merged = SystemProfilerTopologyMerger.merge(data: profilerOutput, into: topology)
                    if merged != topology {
                        topology = merged
                        decoder = PowerMetricsDecoder(topology: topology)
                        controller.updateTopology(topology)
                        if lastSnapshot != nil { lastSnapshot?.topology = topology }
                        try redraw()
                    }

                case .timer(Self.stallTimerIdentifier):
                    let now = ContinuousClock.now
                    if let current = profiler,
                       let startedAt = profilerStartedAt,
                       durationSeconds(startedAt.duration(to: now)) >= profilerTimeout {
                        current.cleanup()
                        profiler = nil
                        profilerStartedAt = nil
                    }
                    let elapsed = durationSeconds(lastValidRecordAt.duration(to: now))
                    if elapsed >= stallTimeout {
                        throw DashboardRuntimeError.stalled(stallTimeout, lastDiagnostic(stderrTail.string))
                    }

                case .signal(SIGWINCH):
                    try redraw()

                case .signal(SIGINT), .signal(SIGTERM), .signal(SIGHUP), .signal(SIGQUIT):
                    return

                case let .error(identifier, code):
                    throw EventLoopError.systemCall("event \(identifier)", code)

                default:
                    break
                }
            }
        }
    }
}

private func lastDiagnostic(_ text: String) -> String {
    text.split(separator: "\n").last.map(String.init) ?? ""
}

private func durationSeconds(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
}
