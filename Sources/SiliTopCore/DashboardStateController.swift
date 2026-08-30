import Foundation

public struct DashboardStateController {
    public private(set) var topology: Topology
    public private(set) var histories = DashboardHistories()

    private let intervalSeconds: Int
    private let staleAfter: TimeInterval
    private let historyCapacity: Int
    private let averageCapacity: Int
    private var previousTimestamp: Date?
    private var cpuAverageSamples: [Double] = []
    private var gpuAverageSamples: [Double] = []
    private var cpuPeak = 0.0
    private var gpuPeak = 0.0
    private var packagePeak = 0.0
    private var coreFrequencyCache: [String: Int] = [:]
    private var fastTierFrequency = 0
    private var slowTierFrequency = 0
    private var memoryTracker = LastGoodMetric<MemoryReading>(unavailableReason: "memory unavailable")
    private var temperatureTracker = LastGoodMetric<[TemperatureReading]>(unavailableReason: "temperature sensors unavailable")
    private var fanTracker = LastGoodMetric<FanCollection>(unavailableReason: "fan sensors unavailable")

    public init(topology: Topology, intervalSeconds: Int, averageSeconds: Int) {
        self.topology = topology
        self.intervalSeconds = max(1, intervalSeconds)
        staleAfter = TimeInterval(max(1, intervalSeconds) * 3)
        let configuration = HistoryConfiguration(
            intervalSeconds: max(1, intervalSeconds),
            averageSeconds: averageSeconds
        )
        historyCapacity = configuration.historyCapacity
        averageCapacity = configuration.averageCapacity
    }

    public mutating func updateTopology(_ topology: Topology) {
        self.topology = topology
    }

    public mutating func accept(
        _ reading: PowerMetricsReading,
        memory: NativeCollectorResult<MemoryReading>,
        temperatures: NativeCollectorResult<[TemperatureReading]>,
        fans: NativeCollectorResult<FanCollection>,
        at now: Date
    ) -> DashboardSnapshot {
        let elapsed = SampleTiming.elapsedSeconds(
            current: reading.timestamp,
            previous: previousTimestamp,
            fallback: Double(intervalSeconds)
        )
        // A timestamp-less record breaks continuity. Keeping the older
        // timestamp would make the next energy sample span two intervals.
        previousTimestamp = reading.timestamp

        let cpuState: MetricState<CPUReading>
        let powerState: MetricState<PowerReading>
        if var cpu = reading.cpu {
            applyFrequencyFallback(to: &cpu)
            cpuState = .fresh(cpu, observedAt: now)
            if
                let energy = cpu.power,
                let cpuWatts = finiteRate(energy.cpuJoules, elapsed: elapsed),
                let gpuWatts = finiteRate(energy.gpuJoules, elapsed: elapsed),
                let aneWatts = finiteRate(energy.aneJoules, elapsed: elapsed),
                energy.packageWatts.isFinite,
                energy.packageWatts >= 0
            {
                let packageWatts = energy.packageWatts

                Self.append(cpuWatts, to: &cpuAverageSamples, capacity: averageCapacity)
                Self.append(gpuWatts, to: &gpuAverageSamples, capacity: averageCapacity)
                Self.append(cpuWatts, to: &histories.cpuPower, capacity: historyCapacity)
                Self.append(gpuWatts, to: &histories.gpuPower, capacity: historyCapacity)
                cpuPeak = max(cpuPeak, cpuWatts)
                gpuPeak = max(gpuPeak, gpuWatts)
                packagePeak = max(packagePeak, packageWatts)

                powerState = .fresh(PowerReading(
                    cpuWatts: cpuWatts,
                    gpuWatts: gpuWatts,
                    aneWatts: aneWatts,
                    packageWatts: packageWatts,
                    cpuAverageWatts: average(cpuAverageSamples),
                    gpuAverageWatts: average(gpuAverageSamples),
                    cpuPeakWatts: cpuPeak,
                    gpuPeakWatts: gpuPeak,
                    packagePeakWatts: packagePeak
                ), observedAt: now)
            } else {
                powerState = .unavailable(reason: "processor energy fields missing or invalid")
            }
        } else {
            cpuState = .unavailable(reason: "processor section missing")
            powerState = .unavailable(reason: "processor power section missing")
        }

        let gpuState = reading.gpu.map { MetricState.fresh($0, observedAt: now) }
            ?? .unavailable(reason: "GPU section missing")
        let networkState: MetricState<NetworkReading>
        if let network = reading.network {
            Self.append(network.inBytesPerSecond, to: &histories.networkIn, capacity: historyCapacity)
            Self.append(network.outBytesPerSecond, to: &histories.networkOut, capacity: historyCapacity)
            networkState = .fresh(network, observedAt: now)
        } else {
            networkState = .unavailable(reason: "network section missing")
        }
        let diskState: MetricState<DiskReading>
        if let disk = reading.disk {
            Self.append(disk.readBytesPerSecond, to: &histories.diskRead, capacity: historyCapacity)
            Self.append(disk.writeBytesPerSecond, to: &histories.diskWrite, capacity: historyCapacity)
            diskState = .fresh(disk, observedAt: now)
        } else {
            diskState = .unavailable(reason: "disk section missing")
        }
        let thermalState = reading.thermalPressure.map { MetricState.fresh($0, observedAt: now) }
            ?? .unavailable(reason: "thermal section missing")

        Self.record(memory, in: &memoryTracker, at: now)
        Self.record(temperatures, in: &temperatureTracker, at: now)
        Self.record(fans, in: &fanTracker, at: now)

        return DashboardSnapshot(
            observedAt: now,
            topology: topology,
            cpu: cpuState,
            gpu: gpuState,
            power: powerState,
            network: networkState,
            disk: diskState,
            memory: memoryTracker.state(at: now, staleAfter: staleAfter),
            temperatures: temperatureTracker.state(at: now, staleAfter: staleAfter),
            fans: fanTracker.state(at: now, staleAfter: staleAfter),
            thermalPressure: thermalState
        )
    }

    private mutating func applyFrequencyFallback(to cpu: inout CPUReading) {
        var cache = coreFrequencyCache
        var fastFrequency = fastTierFrequency
        var slowFrequency = slowTierFrequency
        Self.fillFrequencies(
            &cpu.fastCores,
            tier: "fast",
            cache: &cache,
            tierFrequency: &fastFrequency
        )
        Self.fillFrequencies(
            &cpu.slowCores,
            tier: "slow",
            cache: &cache,
            tierFrequency: &slowFrequency
        )
        coreFrequencyCache = cache
        fastTierFrequency = fastFrequency
        slowTierFrequency = slowFrequency
        cpu.fastFrequencyMHz = cpu.fastCores.map(\.frequencyMHz).max() ?? fastFrequency
        cpu.slowFrequencyMHz = cpu.slowCores.map(\.frequencyMHz).max() ?? slowFrequency
    }

    private static func fillFrequencies(
        _ cores: inout [CoreReading],
        tier: String,
        cache: inout [String: Int],
        tierFrequency: inout Int
    ) {
        // Learn every frequency in the current tier before filling gaps so
        // the result is independent of core order on the first frame.
        let currentTierFrequency = cores.lazy
            .map(\.frequencyMHz)
            .filter { $0 > 0 }
            .max() ?? 0
        for core in cores where core.frequencyMHz > 0 {
            cache["\(tier):\(core.id)"] = core.frequencyMHz
            tierFrequency = max(tierFrequency, core.frequencyMHz)
        }
        for index in cores.indices {
            let key = "\(tier):\(cores[index].id)"
            if cores[index].frequencyMHz == 0, let cached = cache[key], cached > 0 {
                cores[index].frequencyMHz = cached
            } else if cores[index].frequencyMHz == 0, currentTierFrequency > 0 {
                cores[index].frequencyMHz = currentTierFrequency
            } else if cores[index].frequencyMHz == 0, tierFrequency > 0 {
                cores[index].frequencyMHz = tierFrequency
            }
        }
    }

    private func finiteRate(_ energy: Double, elapsed: Double) -> Double? {
        guard energy.isFinite, energy >= 0, elapsed.isFinite else { return nil }
        let result = energy / max(0.001, elapsed)
        return result.isFinite ? result : nil
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let count = Double(values.count)
        let result = values.reduce(0) { $0 + $1 / count }
        return result.isFinite ? result : values.max() ?? 0
    }

    private static func append(_ value: Double, to values: inout [Double], capacity: Int) {
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    private static func record<Value: Equatable>(
        _ result: NativeCollectorResult<Value>,
        in tracker: inout LastGoodMetric<Value>,
        at now: Date
    ) {
        switch result {
        case let .value(value):
            tracker.record(value, at: now)
        case let .unavailable(reason):
            tracker.recordFailure(reason: reason)
        }
    }
}
