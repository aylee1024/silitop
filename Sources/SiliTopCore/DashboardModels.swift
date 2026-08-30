import Foundation

public struct TerminalSize: Equatable, Sendable {
    public let rows: Int
    public let columns: Int

    public init(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
    }
}

public struct PowerReading: Equatable, Sendable {
    public let cpuWatts: Double
    public let gpuWatts: Double
    public let aneWatts: Double
    public let packageWatts: Double
    public let cpuAverageWatts: Double
    public let gpuAverageWatts: Double
    public let cpuPeakWatts: Double
    public let gpuPeakWatts: Double
    public let packagePeakWatts: Double

    public init(
        cpuWatts: Double,
        gpuWatts: Double,
        aneWatts: Double,
        packageWatts: Double,
        cpuAverageWatts: Double,
        gpuAverageWatts: Double,
        cpuPeakWatts: Double,
        gpuPeakWatts: Double,
        packagePeakWatts: Double
    ) {
        self.cpuWatts = cpuWatts
        self.gpuWatts = gpuWatts
        self.aneWatts = aneWatts
        self.packageWatts = packageWatts
        self.cpuAverageWatts = cpuAverageWatts
        self.gpuAverageWatts = gpuAverageWatts
        self.cpuPeakWatts = cpuPeakWatts
        self.gpuPeakWatts = gpuPeakWatts
        self.packagePeakWatts = packagePeakWatts
    }
}

public struct DashboardSnapshot: Equatable {
    public let observedAt: Date
    public var topology: Topology
    public var cpu: MetricState<CPUReading>
    public var gpu: MetricState<GPUReading>
    public var power: MetricState<PowerReading>
    public var network: MetricState<NetworkReading>
    public var disk: MetricState<DiskReading>
    public var memory: MetricState<MemoryReading>
    public var temperatures: MetricState<[TemperatureReading]>
    public var fans: MetricState<FanCollection>
    public var thermalPressure: MetricState<String>

    public init(
        observedAt: Date,
        topology: Topology,
        cpu: MetricState<CPUReading>,
        gpu: MetricState<GPUReading>,
        power: MetricState<PowerReading>,
        network: MetricState<NetworkReading>,
        disk: MetricState<DiskReading>,
        memory: MetricState<MemoryReading>,
        temperatures: MetricState<[TemperatureReading]>,
        fans: MetricState<FanCollection>,
        thermalPressure: MetricState<String>
    ) {
        self.observedAt = observedAt
        self.topology = topology
        self.cpu = cpu
        self.gpu = gpu
        self.power = power
        self.network = network
        self.disk = disk
        self.memory = memory
        self.temperatures = temperatures
        self.fans = fans
        self.thermalPressure = thermalPressure
    }
}

public struct DashboardHistories: Equatable, Sendable {
    public var cpuPower: [Double]
    public var gpuPower: [Double]
    public var networkIn: [Double]
    public var networkOut: [Double]
    public var diskRead: [Double]
    public var diskWrite: [Double]

    public init(
        cpuPower: [Double] = [],
        gpuPower: [Double] = [],
        networkIn: [Double] = [],
        networkOut: [Double] = [],
        diskRead: [Double] = [],
        diskWrite: [Double] = []
    ) {
        self.cpuPower = cpuPower
        self.gpuPower = gpuPower
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.diskRead = diskRead
        self.diskWrite = diskWrite
    }

    public static let example = DashboardHistories(
        cpuPower: [2, 4, 3, 5],
        gpuPower: [1, 1.5, 2, 1.8],
        networkIn: [1_024, 2_048, 1_500],
        networkOut: [512, 1_024, 700],
        diskRead: [4_096, 2_048, 8_192],
        diskWrite: [1_024, 4_096, 2_048]
    )
}
