import Foundation

public enum NativeCollectorResult<Value: Equatable>: Equatable {
    case value(Value)
    case unavailable(reason: String)
}

public enum FanCollection: Equatable, Sendable {
    case fans([FanReading])
    case fanless
}

public struct TemperatureReading: Equatable, Sendable {
    public let name: String
    public let celsius: Double

    public init(name: String, celsius: Double) {
        self.name = name
        self.celsius = celsius
    }

    public static func deduplicatedByName(_ readings: [TemperatureReading]) -> [TemperatureReading] {
        var values: [String: Double] = [:]
        for reading in readings {
            values[reading.name] = reading.celsius
        }
        return values.keys.sorted().compactMap { name in
            values[name].map { TemperatureReading(name: name, celsius: $0) }
        }
    }
}

struct HIDTemperatureFreshnessCache {
    private struct Entry {
        let displayName: String
        var celsius: Double
        var generation: Int
    }

    private var generation = 0
    private var entries: [String: Entry] = [:]

    mutating func reset() {
        generation = 0
        entries.removeAll(keepingCapacity: true)
    }

    mutating func beginWarmRead() {
        generation &+= 1
    }

    mutating func record(identity: String, displayName: String, celsius: Double) {
        entries[identity] = Entry(
            displayName: displayName,
            celsius: celsius,
            generation: generation
        )
    }

    func readings(maximumAge: Int) -> [TemperatureReading] {
        let live = entries.values.compactMap { entry -> TemperatureReading? in
            guard generation - entry.generation <= maximumAge else { return nil }
            return TemperatureReading(name: entry.displayName, celsius: entry.celsius)
        }
        return TemperatureReading.deduplicatedByName(live)
    }
}

enum HIDDiscoveryOutcome {
    static func finish(
        sawReachableEmptyClient: Bool,
        sawAnyServices: Bool
    ) -> NativeCollectorResult<[TemperatureReading]> {
        if sawAnyServices { return .unavailable(reason: "IOHID temperature sensors unreadable") }
        if sawReachableEmptyClient { return .value([]) }
        return .unavailable(reason: "no IOHID temperature sensors found")
    }
}

public struct FanReading: Equatable, Sendable {
    public let index: Int
    public let rpm: Double
    public let maximumRPM: Double

    public init(index: Int, rpm: Double, maximumRPM: Double) {
        self.index = index
        self.rpm = rpm
        self.maximumRPM = maximumRPM
    }
}

public struct DieTemperature: Equatable, Sendable {
    public let zone: Int
    public let celsius: Double
}

public struct ClassifiedTemperatures: Equatable, Sendable {
    public let cpuDie: [DieTemperature]
    public let gpuDie: [DieTemperature]
    public let other: [String: Double]
}

public enum TemperatureClassifier {
    public static func classify(
        _ readings: [TemperatureReading],
        gpuDieZoneCount: Int = 2
    ) -> ClassifiedTemperatures {
        var die: [DieTemperature] = []
        var other: [String: Double] = [:]
        for reading in readings {
            switch reading.name {
            case "PMU tcal":
                continue
            case "NAND CH0 temp":
                other["SSD"] = reading.celsius
            case "gas gauge battery":
                other["Battery"] = reading.celsius
            default:
                if reading.name.hasPrefix("PMU tdie"),
                   let zone = Int(reading.name.dropFirst("PMU tdie".count)) {
                    die.append(DieTemperature(zone: zone, celsius: reading.celsius))
                } else if reading.name.hasPrefix("PMU tdev") {
                    let zone = String(reading.name.dropFirst("PMU tdev".count))
                    if Int(zone) != nil {
                        other["SoC \(zone)"] = reading.celsius
                    }
                }
            }
        }
        die.sort { $0.zone < $1.zone }
        let gpuCount = max(0, gpuDieZoneCount)
        guard die.count > gpuCount else {
            return ClassifiedTemperatures(cpuDie: die, gpuDie: [], other: other)
        }
        return ClassifiedTemperatures(
            cpuDie: Array(die.dropLast(gpuCount)),
            gpuDie: Array(die.suffix(gpuCount)),
            other: other
        )
    }
}

public enum SMCNumericDecoder {
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 4
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            let value = (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
            return Double(value)
        case "ui8 ":
            guard let value = bytes.first else { return nil }
            return Double(value)
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            var value: Float = 0
            withUnsafeMutableBytes(of: &value) { destination in
                destination.copyBytes(from: bytes.prefix(4))
            }
            let result = Double(value)
            return result.isFinite ? result : nil
        default:
            return nil
        }
    }
}

public enum SMCFanCountDecoder {
    public static func decode(type: String, bytes: [UInt8]) -> Int? {
        guard ["ui8 ", "ui16", "ui32"].contains(type),
              let value = SMCNumericDecoder.decode(type: type, bytes: bytes),
              value.isFinite,
              value >= 0,
              value <= 255,
              value.rounded() == value else {
            return nil
        }
        return Int(value)
    }
}
