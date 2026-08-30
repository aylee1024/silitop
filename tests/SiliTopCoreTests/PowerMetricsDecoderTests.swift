import Foundation
import XCTest
@testable import SiliTopCore

final class PowerMetricsDecoderTests: XCTestCase {
    private let topology = Topology(
        name: "Apple M5 Pro",
        fastLabel: "Super",
        slowLabel: "Performance",
        fastPrefix: "S",
        slowPrefix: "P",
        fastCoreCount: 6,
        slowCoreCount: 12,
        gpuCoreCount: 20
    )

    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
    }

    private func validSample() -> [String: Any] {
        [
            "timestamp": Date(timeIntervalSince1970: 1_000),
            "processor": [
                "clusters": [
                    [
                        "name": "S-Cluster",
                        "freq_hz": 4_000_000_000.0,
                        "cpus": [["cpu": 0, "idle_ratio": 0.5, "freq_hz": 4_000_000_000.0]],
                    ],
                    [
                        "name": "P-Cluster",
                        "freq_hz": 3_000_000_000.0,
                        "cpus": [["cpu": 1, "idle_ratio": 0.75, "freq_hz": 3_000_000_000.0]],
                    ],
                ],
                "cpu_energy": 5_000.0,
                "gpu_energy": 2_000.0,
                "ane_energy": 100.0,
                "combined_power": 30_000.0,
            ],
            "gpu": ["idle_ratio": 0.25, "freq_hz": 1_000.0],
            "thermal_pressure": "Nominal",
            "network": ["ibyte_rate": 1_024.0, "obyte_rate": 2_048.0],
            "disk": ["rbytes_per_s": 4_096.0, "wbytes_per_s": 8_192.0],
        ]
    }

    func testDecodePreservesPowerUnitsAndBucketsCoreTiers() throws {
        let sample = PowerMetricsDecoder(topology: topology).decode(
            plistRecord: try plist(validSample())
        )

        XCTAssertEqual(sample?.cpu?.power?.cpuJoules, 5.0)
        XCTAssertEqual(sample?.cpu?.power?.gpuJoules, 2.0)
        XCTAssertEqual(sample?.cpu?.power?.aneJoules, 0.1)
        XCTAssertEqual(sample?.cpu?.power?.packageWatts, 30.0)
        XCTAssertEqual(sample?.cpu?.fastCores.map(\.id), [0])
        XCTAssertEqual(sample?.cpu?.slowCores.map(\.id), [1])
        XCTAssertEqual(sample?.cpu?.fastActivePercent, 50)
        XCTAssertEqual(sample?.cpu?.slowActivePercent, 25)
        XCTAssertEqual(sample?.gpu, GPUReading(activePercent: 75, frequencyMHz: 1_000))
        XCTAssertEqual(sample?.network, NetworkReading(inBytesPerSecond: 1_024, outBytesPerSecond: 2_048))
        XCTAssertEqual(sample?.disk, DiskReading(readBytesPerSecond: 4_096, writeBytesPerSecond: 8_192))
        XCTAssertEqual(sample?.thermalPressure, "Nominal")
    }

    func testMissingRequiredProcessorFieldsMakeOnlyCPUPanelUnavailable() throws {
        var value = validSample()
        value["processor"] = ["clusters": []]

        let sample = PowerMetricsDecoder(topology: topology).decode(
            plistRecord: try plist(value)
        )

        XCTAssertNotNil(sample)
        XCTAssertNil(sample?.cpu)
        XCTAssertNotNil(sample?.gpu)
        XCTAssertNotNil(sample?.network)
    }

    func testMissingEnergyFieldsMakeOnlyPowerUnavailable() throws {
        var value = validSample()
        var processor = value["processor"] as! [String: Any]
        processor.removeValue(forKey: "cpu_energy")
        value["processor"] = processor

        let sample = PowerMetricsDecoder(topology: topology).decode(
            plistRecord: try plist(value)
        )

        XCTAssertNotNil(sample?.cpu)
        XCTAssertNil(sample?.cpu?.power)
        XCTAssertNotNil(sample?.gpu)
    }

    func testPartialOptionalBlocksAreUnavailableInsteadOfZero() throws {
        var value = validSample()
        value["gpu"] = ["freq_hz": 1_000.0]
        value["network"] = ["obyte_rate": 2_048.0]
        value["disk"] = ["rbytes_per_s": 4_096.0]

        let sample = PowerMetricsDecoder(topology: topology).decode(
            plistRecord: try plist(value)
        )

        XCTAssertNil(sample?.gpu)
        XCTAssertNil(sample?.network)
        XCTAssertNil(sample?.disk)
    }

    func testMissingGPUFrequencyDoesNotBecomeFreshZero() throws {
        var value = validSample()
        value["gpu"] = ["idle_ratio": 0.5]

        let sample = PowerMetricsDecoder(topology: topology).decode(plistRecord: try plist(value))

        XCTAssertNil(sample?.gpu)
    }

    func testMissingThermalSectionIsUnavailableInsteadOfUnknownString() throws {
        var fixture = validSample()
        fixture.removeValue(forKey: "thermal_pressure")

        let sample = PowerMetricsDecoder(topology: topology).decode(plistRecord: try plist(fixture))

        XCTAssertNil(sample?.thermalPressure)
    }

    func testMalformedPlistIsRejected() {
        XCTAssertNil(PowerMetricsDecoder(topology: topology).decode(
            plistRecord: Data("not a plist".utf8)
        ))
    }

    func testStructurallyEmptyPlistIsNotCountedAsAValidSample() throws {
        XCTAssertNil(PowerMetricsDecoder(topology: topology).decode(
            plistRecord: try plist([:])
        ))
        XCTAssertNil(PowerMetricsDecoder(topology: topology).decode(
            plistRecord: try plist(["timestamp": Date()])
        ))
    }

    func testGPUFrequencyConvertsHertzOnlyWhenNeeded() throws {
        var value = validSample()
        value["gpu"] = ["idle_ratio": 0.5, "freq_hz": 1_200_000_000.0]

        let sample = PowerMetricsDecoder(topology: topology).decode(
            plistRecord: try plist(value)
        )

        XCTAssertEqual(sample?.gpu?.frequencyMHz, 1_200)
    }

    func testMalformedCPUCoresDoNotProduceFreshZeroCPU() throws {
        var value = validSample()
        var processor = value["processor"] as! [String: Any]
        processor["clusters"] = [[
            "name": "S-Cluster",
            "cpus": [["cpu": 0, "freq_hz": 4_000_000_000.0]],
        ]]
        value["processor"] = processor

        let sample = PowerMetricsDecoder(topology: topology).decode(plistRecord: try plist(value))

        XCTAssertNil(sample?.cpu)
        XCTAssertNotNil(sample?.gpu)
        XCTAssertNotNil(sample?.network)
    }

    func testNegativeCountersRatesAndBlankThermalAreUnavailable() throws {
        var value = validSample()
        var processor = value["processor"] as! [String: Any]
        processor["cpu_energy"] = -1.0
        value["processor"] = processor
        value["network"] = ["ibyte_rate": -1.0, "obyte_rate": 2_048.0]
        value["disk"] = ["rbytes_per_s": 4_096.0, "wbytes_per_s": -1.0]
        value["thermal_pressure"] = "  "

        let sample = PowerMetricsDecoder(topology: topology).decode(plistRecord: try plist(value))

        XCTAssertNotNil(sample?.cpu)
        XCTAssertNil(sample?.cpu?.power)
        XCTAssertNil(sample?.network)
        XCTAssertNil(sample?.disk)
        XCTAssertNil(sample?.thermalPressure)
    }

    func testOutOfRangeIdleRatiosAreRejected() throws {
        var value = validSample()
        var processor = value["processor"] as! [String: Any]
        processor["clusters"] = [[
            "name": "S-Cluster",
            "cpus": [["cpu": 0, "idle_ratio": 1.5, "freq_hz": 4_000_000_000.0]],
        ]]
        value["processor"] = processor
        value["gpu"] = ["idle_ratio": -0.5, "freq_hz": 1_000.0]

        let sample = PowerMetricsDecoder(topology: topology).decode(plistRecord: try plist(value))

        XCTAssertNil(sample?.cpu)
        XCTAssertNil(sample?.gpu)
    }

    func testHugeFiniteFrequenciesAreRejectedWithoutIntegerTrap() throws {
        var value = validSample()
        var processor = value["processor"] as! [String: Any]
        processor["clusters"] = [[
            "name": "S-Cluster",
            "freq_hz": 1e300,
            "cpus": [["cpu": 0, "idle_ratio": 0.5, "freq_hz": 1e300]],
        ]]
        value["processor"] = processor
        value["gpu"] = ["idle_ratio": 0.5, "freq_hz": 1e300]

        let sample = PowerMetricsDecoder(topology: topology).decode(plistRecord: try plist(value))

        XCTAssertNil(sample?.cpu)
        XCTAssertNil(sample?.gpu)
        XCTAssertNotNil(sample?.network)
    }
}

final class TimingContractTests: XCTestCase {
    func testElapsedSecondsUsesTimestampAndClampsNonPositiveDeltas() {
        let old = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 102)

        XCTAssertEqual(SampleTiming.elapsedSeconds(current: newer, previous: old, fallback: 5), 2)
        XCTAssertEqual(SampleTiming.elapsedSeconds(current: old, previous: old, fallback: 5), 0.001)
        XCTAssertEqual(SampleTiming.elapsedSeconds(current: newer, previous: nil, fallback: 5), 5)
    }

    func testHistorySizingUsesWallClockSeconds() {
        XCTAssertEqual(HistoryConfiguration(intervalSeconds: 1, averageSeconds: 30).historyCapacity, 120)
        XCTAssertEqual(HistoryConfiguration(intervalSeconds: 2, averageSeconds: 30).historyCapacity, 60)
        XCTAssertEqual(HistoryConfiguration(intervalSeconds: 5, averageSeconds: 30).historyCapacity, 30)
        XCTAssertEqual(HistoryConfiguration(intervalSeconds: 5, averageSeconds: 30).averageCapacity, 6)
        XCTAssertEqual(HistoryConfiguration(intervalSeconds: 5, averageSeconds: 1).averageCapacity, 1)
    }
}
