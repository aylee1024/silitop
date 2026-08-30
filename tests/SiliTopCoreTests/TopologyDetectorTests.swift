import Foundation
import XCTest
@testable import SiliTopCore

final class TopologyDetectorTests: XCTestCase {
    func testDetectsM5PerflevelNamesAndMaximumCoreCounts() {
        let values = [
            "machdep.cpu.brand_string": "Apple M5 Pro",
            "hw.perflevel0.name": "Super",
            "hw.perflevel0.physicalcpu_max": "6",
            "hw.perflevel1.name": "Performance",
            "hw.perflevel1.physicalcpu_max": "12",
        ]

        let topology = TopologyDetector(sysctl: { values[$0] }).detect()

        XCTAssertEqual(topology.fastLabel, "Super")
        XCTAssertEqual(topology.slowLabel, "Performance")
        XCTAssertEqual(topology.fastPrefix, "S")
        XCTAssertEqual(topology.slowPrefix, "P")
        XCTAssertEqual(topology.fastCoreCount, 6)
        XCTAssertEqual(topology.slowCoreCount, 12)
        XCTAssertEqual(topology.powerLimits, PowerLimits(cpuWatts: 30, gpuWatts: 30, aneWatts: 8))
    }

    func testDetectsEfficiencyAndPerformanceCaseInsensitively() {
        let values = [
            "machdep.cpu.brand_string": "Apple M2",
            "hw.perflevel0.name": "performance",
            "hw.perflevel0.physicalcpu_max": "4",
            "hw.perflevel1.name": "efficiency",
            "hw.perflevel1.physicalcpu_max": "4",
        ]

        let topology = TopologyDetector(sysctl: { values[$0] }).detect()

        XCTAssertEqual(topology.fastLabel, "performance")
        XCTAssertEqual(topology.slowLabel, "efficiency")
        XCTAssertEqual(topology.fastPrefix, "P")
        XCTAssertEqual(topology.slowPrefix, "E")
    }

    func testProfilerXMLFillsOnlyMissingChipAndGPUFields() throws {
        let profiler: [[String: Any]] = [
            ["_dataType": "SPHardwareDataType", "_items": [[
                "chip_type": "Apple M5 Max",
                "number_processors": "proc 18:6:0:12",
            ]]],
            ["_dataType": "SPDisplaysDataType", "_items": [["sppci_cores": "40"]]],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: profiler,
            format: .xml,
            options: 0
        )

        let initial = TopologyDetector(sysctl: { _ in nil }).detect()
        let merged = SystemProfilerTopologyMerger.merge(data: data, into: initial)

        XCTAssertEqual(merged.name, "Apple M5 Max")
        XCTAssertEqual(merged.gpuCoreCount, 40)
        XCTAssertEqual(merged.powerLimits, PowerLimits(cpuWatts: 40, gpuWatts: 60, aneWatts: 8))
        XCTAssertEqual(merged.fastLabel, "Super")
        XCTAssertEqual(merged.slowLabel, "Performance")
        XCTAssertEqual(merged.fastPrefix, "S")
        XCTAssertEqual(merged.slowPrefix, "P")
        XCTAssertEqual(merged.fastCoreCount, 6)
        XCTAssertEqual(merged.slowCoreCount, 12)
    }

    func testProfilerOnlyM5TopologyClassifiesBothPowermetricsTiers() throws {
        let profiler: [[String: Any]] = [[
            "_dataType": "SPHardwareDataType",
            "_items": [[
                "chip_type": "Apple M5 Pro",
                "number_processors": "proc 18:6:0:12",
            ]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: profiler, format: .xml, options: 0)
        let topology = SystemProfilerTopologyMerger.merge(
            data: data,
            into: TopologyDetector(sysctl: { _ in nil }).detect()
        )
        let sample: [String: Any] = [
            "processor": [
                "clusters": [
                    ["name": "S-Cluster", "cpus": [["cpu": 0, "idle_ratio": 0.5]]],
                    ["name": "P0-Cluster", "cpus": [["cpu": 6, "idle_ratio": 0.75]]],
                ],
                "cpu_energy": 1_000.0,
                "gpu_energy": 0.0,
                "ane_energy": 0.0,
                "combined_power": 1_000.0,
            ],
        ]
        let record = try PropertyListSerialization.data(fromPropertyList: sample, format: .binary, options: 0)
        let reading = PowerMetricsDecoder(topology: topology).decode(plistRecord: record)

        XCTAssertEqual(reading?.cpu?.fastCores.map(\.id), [0])
        XCTAssertEqual(reading?.cpu?.slowCores.map(\.id), [6])
    }

    func testTotalDetectionFailureUsesUnknownsNotFabricatedCounts() {
        let topology = TopologyDetector(sysctl: { _ in nil }).detect()

        XCTAssertNil(topology.name)
        XCTAssertNil(topology.fastCoreCount)
        XCTAssertNil(topology.slowCoreCount)
        XCTAssertNil(topology.gpuCoreCount)
        XCTAssertEqual(topology.fastLabel, "Performance")
        XCTAssertEqual(topology.slowLabel, "Efficiency")
        XCTAssertEqual(topology.fastPrefix, "P")
        XCTAssertEqual(topology.slowPrefix, "E")
    }

    func testNativeIntegerSysctlSuppliesCoreCountsWithoutTextConversion() {
        let topology = TopologyDetector(
            sysctl: { [
                "machdep.cpu.brand_string": "Apple M5 Pro",
                "hw.perflevel0.name": "Super",
                "hw.perflevel1.name": "Performance",
            ][$0] },
            integerSysctl: { [
                "hw.perflevel0.physicalcpu_max": 6,
                "hw.perflevel1.physicalcpu_max": 12,
            ][$0] }
        ).detect()

        XCTAssertEqual(topology.fastCoreCount, 6)
        XCTAssertEqual(topology.slowCoreCount, 12)
    }
}
