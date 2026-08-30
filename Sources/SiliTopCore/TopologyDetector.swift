import Foundation

public struct TopologyDetector {
    private let readSysctl: (String) -> String?
    private let readIntegerSysctl: (String) -> UInt64?

    public init(
        sysctl: @escaping (String) -> String?,
        integerSysctl: @escaping (String) -> UInt64? = { _ in nil }
    ) {
        readSysctl = sysctl
        readIntegerSysctl = integerSysctl
    }

    public func detect() -> Topology {
        let fastLabel = nonempty(readSysctl("hw.perflevel0.name")) ?? "Performance"
        let slowLabel = nonempty(readSysctl("hw.perflevel1.name")) ?? "Efficiency"
        let name = nonempty(readSysctl("machdep.cpu.brand_string"))
        return Topology(
            name: name,
            fastLabel: fastLabel,
            slowLabel: slowLabel,
            fastPrefix: prefix(of: fastLabel, fallback: "F"),
            slowPrefix: prefix(of: slowLabel, fallback: "S"),
            fastCoreCount: coreCount(level: 0),
            slowCoreCount: coreCount(level: 1),
            gpuCoreCount: nil
        )
    }

    private func coreCount(level: Int) -> Int? {
        for suffix in ["physicalcpu_max", "physicalcpu"] {
            let key = "hw.perflevel\(level).\(suffix)"
            if let value = readIntegerSysctl(key), value <= UInt64(Int.max) {
                return Int(value)
            }
            if let value = integer(readSysctl(key)) { return value }
        }
        return nil
    }
}

public enum SystemProfilerTopologyMerger {
    public static func merge(data: Data, into topology: Topology) -> Topology {
        guard
            let value = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let sections = value as? [[String: Any]]
        else {
            return topology
        }

        var result = topology
        for section in sections {
            guard
                let kind = section["_dataType"] as? String,
                let items = section["_items"] as? [[String: Any]]
            else {
                continue
            }
            if kind == "SPHardwareDataType", result.name == nil {
                result.name = items.lazy.compactMap { nonempty($0["chip_type"] as? String) }.first
                result.powerLimits = PowerLimits.forChip(named: result.name)
            }
            if kind == "SPDisplaysDataType", result.gpuCoreCount == nil {
                result.gpuCoreCount = items.lazy.compactMap { item in
                    if let text = item["sppci_cores"] as? String { return integer(text) }
                    if let value = item["sppci_cores"] as? NSNumber { return value.intValue }
                    return nil
                }.first
            }
        }
        return result
    }
}

private func nonempty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func integer(_ value: String?) -> Int? {
    guard let value = nonempty(value) else { return nil }
    return Int(value)
}

private func prefix(of value: String, fallback: String) -> String {
    guard let first = value.first else { return fallback }
    return String(first).uppercased()
}
