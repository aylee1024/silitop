import Foundation

public struct ChildCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum PowerMetricsSamplerSet: Equatable, Sendable {
    case full
    case essential

    public var value: String {
        switch self {
        case .full:
            return "cpu_power,gpu_power,thermal,network,disk"
        case .essential:
            return "cpu_power,gpu_power,thermal"
        }
    }
}

public struct PowerMetricsCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(intervalSeconds: Int, samplerSet: PowerMetricsSamplerSet) {
        executable = "/usr/bin/nice"
        arguments = [
            "-n", "10", "/usr/bin/powermetrics",
            "-b", "0",
            "-f", "plist",
            "-o", "-",
            "-i", String(max(1, intervalSeconds) * 1_000),
            "--samplers", samplerSet.value,
        ]
    }

    public static func stallTimeout(intervalSeconds: Int) -> TimeInterval {
        max(3, Double(max(1, intervalSeconds) * 3))
    }

    public var childCommand: ChildCommand {
        ChildCommand(executable: executable, arguments: arguments)
    }
}

public struct ByteTail: Equatable, Sendable {
    public let capacity: Int
    public private(set) var data = Data()

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    public mutating func append(_ bytes: Data) {
        guard capacity > 0 else {
            data.removeAll(keepingCapacity: false)
            return
        }
        if bytes.count >= capacity {
            data = Data(bytes.suffix(capacity))
            return
        }
        data.append(bytes)
        if data.count > capacity {
            data.removeFirst(data.count - capacity)
        }
    }

    public var string: String {
        String(decoding: data, as: UTF8.self)
    }
}
