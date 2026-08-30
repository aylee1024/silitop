import Foundation

public struct Topology: Equatable, Sendable {
    public var name: String?
    public var fastLabel: String
    public var slowLabel: String
    public var fastPrefix: String
    public var slowPrefix: String
    public var fastCoreCount: Int?
    public var slowCoreCount: Int?
    public var gpuCoreCount: Int?
    public var powerLimits: PowerLimits

    public init(
        name: String?,
        fastLabel: String,
        slowLabel: String,
        fastPrefix: String,
        slowPrefix: String,
        fastCoreCount: Int?,
        slowCoreCount: Int?,
        gpuCoreCount: Int?,
        powerLimits: PowerLimits? = nil
    ) {
        self.name = name
        self.fastLabel = fastLabel
        self.slowLabel = slowLabel
        self.fastPrefix = fastPrefix
        self.slowPrefix = slowPrefix
        self.fastCoreCount = fastCoreCount
        self.slowCoreCount = slowCoreCount
        self.gpuCoreCount = gpuCoreCount
        self.powerLimits = powerLimits ?? PowerLimits.forChip(named: name)
    }
}

public struct PowerLimits: Equatable, Sendable {
    public let cpuWatts: Double
    public let gpuWatts: Double
    public let aneWatts: Double

    public init(cpuWatts: Double, gpuWatts: Double, aneWatts: Double) {
        self.cpuWatts = cpuWatts
        self.gpuWatts = gpuWatts
        self.aneWatts = aneWatts
    }

    public static func forChip(named name: String?) -> PowerLimits {
        let value = name ?? ""
        if value.localizedCaseInsensitiveContains("Ultra") {
            return PowerLimits(cpuWatts: 80, gpuWatts: 120, aneWatts: 8)
        }
        if value.localizedCaseInsensitiveContains("Max") {
            return PowerLimits(cpuWatts: 40, gpuWatts: 60, aneWatts: 8)
        }
        if value.localizedCaseInsensitiveContains("Pro") {
            return PowerLimits(cpuWatts: 30, gpuWatts: 30, aneWatts: 8)
        }
        return PowerLimits(cpuWatts: 20, gpuWatts: 20, aneWatts: 8)
    }
}

public struct CoreReading: Equatable, Sendable {
    public let id: Int
    public var activePercent: Int
    public var frequencyMHz: Int
}

public struct PowerEnergyReading: Equatable, Sendable {
    public let cpuJoules: Double
    public let gpuJoules: Double
    public let aneJoules: Double
    public let packageWatts: Double
}

public struct CPUReading: Equatable, Sendable {
    public var fastCores: [CoreReading]
    public var slowCores: [CoreReading]
    public let fastActivePercent: Int
    public let slowActivePercent: Int
    public var fastFrequencyMHz: Int
    public var slowFrequencyMHz: Int
    public let power: PowerEnergyReading?
}

public struct GPUReading: Equatable, Sendable {
    public let activePercent: Int
    public let frequencyMHz: Int

    public init(activePercent: Int, frequencyMHz: Int) {
        self.activePercent = activePercent
        self.frequencyMHz = frequencyMHz
    }
}

public struct NetworkReading: Equatable, Sendable {
    public let inBytesPerSecond: Double
    public let outBytesPerSecond: Double

    public init(inBytesPerSecond: Double, outBytesPerSecond: Double) {
        self.inBytesPerSecond = inBytesPerSecond
        self.outBytesPerSecond = outBytesPerSecond
    }
}

public struct DiskReading: Equatable, Sendable {
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double

    public init(readBytesPerSecond: Double, writeBytesPerSecond: Double) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }
}

public struct PowerMetricsReading: Equatable, Sendable {
    public let timestamp: Date?
    public let cpu: CPUReading?
    public let gpu: GPUReading?
    public let thermalPressure: String?
    public let network: NetworkReading?
    public let disk: DiskReading?
}

public struct HistoryConfiguration: Equatable, Sendable {
    public let historyCapacity: Int
    public let averageCapacity: Int

    public init(intervalSeconds: Int, averageSeconds: Int) {
        historyCapacity = max(30, 120 / max(intervalSeconds, 1))
        averageCapacity = max(1, averageSeconds / max(intervalSeconds, 1))
    }
}

public enum SampleTiming {
    public static func elapsedSeconds(
        current: Date?,
        previous: Date?,
        fallback: Double
    ) -> Double {
        guard let current, let previous else { return fallback }
        return max(current.timeIntervalSince(previous), 0.001)
    }
}

public struct SampleTimestampGate: Equatable, Sendable {
    private var lastTimestamp: Date?

    public init() {}

    public mutating func shouldAccept(_ timestamp: Date?) -> Bool {
        guard let timestamp else { return true }
        if let lastTimestamp, timestamp <= lastTimestamp { return false }
        lastTimestamp = timestamp
        return true
    }
}
