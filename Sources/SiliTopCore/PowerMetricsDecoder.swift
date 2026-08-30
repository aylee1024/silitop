import Foundation

public struct PowerMetricsDecoder {
    public let topology: Topology

    public init(topology: Topology) {
        self.topology = topology
    }

    public func decode(plistRecord data: Data) -> PowerMetricsReading? {
        guard
            let root = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let dictionary = root as? [String: Any]
        else {
            return nil
        }

        return PowerMetricsReading(
            timestamp: dictionary["timestamp"] as? Date,
            cpu: decodeCPU(dictionary["processor"]),
            gpu: decodeGPU(dictionary["gpu"]),
            thermalPressure: dictionary["thermal_pressure"] as? String,
            network: decodeNetwork(dictionary["network"]),
            disk: decodeDisk(dictionary["disk"])
        )
    }

    private func decodeCPU(_ value: Any?) -> CPUReading? {
        guard
            let processor = value as? [String: Any],
            let clusters = processor["clusters"] as? [[String: Any]],
            !clusters.isEmpty
        else {
            return nil
        }

        var fast: [CoreReading] = []
        var slow: [CoreReading] = []
        for cluster in clusters {
            guard let name = cluster["name"] as? String, !name.isEmpty else { continue }
            let clusterFrequency = frequencyMHz(cluster["freq_hz"])
            let cpus = cluster["cpus"] as? [[String: Any]] ?? []
            for cpu in cpus {
                guard let id = finiteInt(cpu["cpu"]) else { continue }
                let idle = finiteDouble(cpu["idle_ratio"]) ?? 1
                let active = clampPercent((1 - idle) * 100)
                let ownFrequency = frequencyMHz(cpu["freq_hz"])
                let reading = CoreReading(
                    id: id,
                    activePercent: active,
                    frequencyMHz: ownFrequency > 0 ? ownFrequency : clusterFrequency
                )
                if matchesPrefix(name, topology.slowPrefix) {
                    slow.append(reading)
                } else {
                    fast.append(reading)
                }
            }
        }

        return CPUReading(
            fastCores: fast,
            slowCores: slow,
            fastActivePercent: averagePercent(fast),
            slowActivePercent: averagePercent(slow),
            fastFrequencyMHz: fast.map(\.frequencyMHz).max() ?? 0,
            slowFrequencyMHz: slow.map(\.frequencyMHz).max() ?? 0,
            power: decodePower(processor)
        )
    }

    private func decodePower(_ processor: [String: Any]) -> PowerEnergyReading? {
        guard
            let cpuEnergy = finiteDouble(processor["cpu_energy"]),
            let gpuEnergy = finiteDouble(processor["gpu_energy"]),
            let aneEnergy = finiteDouble(processor["ane_energy"]),
            let combinedPower = finiteDouble(processor["combined_power"])
        else {
            return nil
        }
        return PowerEnergyReading(
            cpuJoules: cpuEnergy / 1_000,
            gpuJoules: gpuEnergy / 1_000,
            aneJoules: aneEnergy / 1_000,
            packageWatts: combinedPower / 1_000
        )
    }

    private func decodeGPU(_ value: Any?) -> GPUReading? {
        guard
            let gpu = value as? [String: Any],
            let idle = finiteDouble(gpu["idle_ratio"]),
            let rawFrequency = finiteDouble(gpu["freq_hz"])
        else {
            return nil
        }
        let mhz = rawFrequency > 1_000_000 ? Int(rawFrequency / 1_000_000) : Int(rawFrequency)
        return GPUReading(activePercent: clampPercent((1 - idle) * 100), frequencyMHz: mhz)
    }

    private func decodeNetwork(_ value: Any?) -> NetworkReading? {
        guard
            let network = value as? [String: Any],
            let input = finiteDouble(network["ibyte_rate"]),
            let output = finiteDouble(network["obyte_rate"])
        else {
            return nil
        }
        return NetworkReading(inBytesPerSecond: input, outBytesPerSecond: output)
    }

    private func decodeDisk(_ value: Any?) -> DiskReading? {
        guard
            let disk = value as? [String: Any],
            let read = finiteDouble(disk["rbytes_per_s"]),
            let write = finiteDouble(disk["wbytes_per_s"])
        else {
            return nil
        }
        return DiskReading(readBytesPerSecond: read, writeBytesPerSecond: write)
    }
}

private func finiteDouble(_ value: Any?) -> Double? {
    let result: Double?
    if let number = value as? NSNumber {
        result = number.doubleValue
    } else if let value = value as? Double {
        result = value
    } else if let value = value as? Int {
        result = Double(value)
    } else {
        result = nil
    }
    guard let result, result.isFinite else { return nil }
    return result
}

private func finiteInt(_ value: Any?) -> Int? {
    guard let number = finiteDouble(value), number >= Double(Int.min), number <= Double(Int.max) else {
        return nil
    }
    return Int(number)
}

private func frequencyMHz(_ value: Any?) -> Int {
    guard let value = finiteDouble(value), value > 0 else { return 0 }
    return Int(value / 1_000_000)
}

private func clampPercent(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return max(0, min(Int(value.rounded()), 100))
}

private func averagePercent(_ cores: [CoreReading]) -> Int {
    guard !cores.isEmpty else { return 0 }
    return cores.map(\.activePercent).reduce(0, +) / cores.count
}

private func matchesPrefix(_ name: String, _ prefix: String) -> Bool {
    guard let first = name.first, let expected = prefix.first else { return false }
    return String(first).caseInsensitiveCompare(String(expected)) == .orderedSame
}
