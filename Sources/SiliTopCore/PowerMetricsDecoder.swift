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

        let timestamp = dictionary["timestamp"] as? Date
        let cpu = decodeCPU(dictionary["processor"])
        let gpu = decodeGPU(dictionary["gpu"])
        let thermalPressure = nonblank(dictionary["thermal_pressure"] as? String)
        let network = decodeNetwork(dictionary["network"])
        let disk = decodeDisk(dictionary["disk"])
        guard cpu != nil || gpu != nil || thermalPressure != nil || network != nil || disk != nil else {
            return nil
        }
        return PowerMetricsReading(
            timestamp: timestamp,
            cpu: cpu,
            gpu: gpu,
            thermalPressure: thermalPressure,
            network: network,
            disk: disk
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
            guard
                let name = cluster["name"] as? String,
                !name.isEmpty,
                let clusterFrequency = frequencyMHz(cluster["freq_hz"])
            else {
                continue
            }
            let cpus = cluster["cpus"] as? [[String: Any]] ?? []
            for cpu in cpus {
                guard
                    let id = finiteInt(cpu["cpu"]),
                    let idle = ratio(cpu["idle_ratio"]),
                    let ownFrequency = frequencyMHz(cpu["freq_hz"])
                else {
                    continue
                }
                let active = clampPercent((1 - idle) * 100)
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

        guard !fast.isEmpty || !slow.isEmpty else { return nil }

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
            let combinedPower = finiteDouble(processor["combined_power"]),
            cpuEnergy >= 0,
            gpuEnergy >= 0,
            aneEnergy >= 0,
            combinedPower >= 0
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
            gpu["freq_hz"] != nil,
            let idle = ratio(gpu["idle_ratio"]),
            let mhz = frequencyMHz(gpu["freq_hz"])
        else {
            return nil
        }
        return GPUReading(activePercent: clampPercent((1 - idle) * 100), frequencyMHz: mhz)
    }

    private func decodeNetwork(_ value: Any?) -> NetworkReading? {
        guard
            let network = value as? [String: Any],
            let input = finiteDouble(network["ibyte_rate"]),
            let output = finiteDouble(network["obyte_rate"]),
            input >= 0,
            output >= 0
        else {
            return nil
        }
        return NetworkReading(inBytesPerSecond: input, outBytesPerSecond: output)
    }

    private func decodeDisk(_ value: Any?) -> DiskReading? {
        guard
            let disk = value as? [String: Any],
            let read = finiteDouble(disk["rbytes_per_s"]),
            let write = finiteDouble(disk["wbytes_per_s"]),
            read >= 0,
            write >= 0
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
    guard
        let number = finiteDouble(value),
        number >= Double(Int.min),
        number < Double(Int.max),
        number.rounded(.towardZero) == number
    else {
        return nil
    }
    return Int(number)
}

private func ratio(_ value: Any?) -> Double? {
    guard let value = finiteDouble(value), value >= 0, value <= 1 else { return nil }
    return value
}

private func nonblank(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
}

private func frequencyMHz(_ value: Any?) -> Int? {
    guard value != nil else { return 0 }
    guard let value = finiteDouble(value), value >= 0 else { return nil }
    if value == 0 { return 0 }
    let mhz = value > 1_000_000 ? value / 1_000_000 : value
    // Generous headroom above any Apple Silicon clock while rejecting
    // corrupt finite values before Double-to-Int conversion.
    guard mhz <= 100_000 else { return nil }
    return Int(mhz)
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
