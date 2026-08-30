import Foundation
import XCTest
@testable import SiliTopCore

final class ExtractorParityTests: XCTestCase {
    private let decoder = PowerMetricsDecoder(topology: Topology(
        name: "Apple M5 Pro",
        fastLabel: "Super", slowLabel: "Performance",
        fastPrefix: "S", slowPrefix: "P",
        fastCoreCount: 1, slowCoreCount: 1, gpuCoreCount: 20
    ))

    func testMissingProcessorMakesOnlyCPUNil() throws {
        var value = fixture(); value.removeValue(forKey: "processor")
        let reading = decoder.decode(plistRecord: try plist(value))
        XCTAssertNil(reading?.cpu); XCTAssertNotNil(reading?.gpu)
    }

    func testNonDictionaryProcessorMakesOnlyCPUNil() throws {
        var value = fixture(); value["processor"] = "broken"
        XCTAssertNil(decoder.decode(plistRecord: try plist(value))?.cpu)
    }

    func testMissingClustersMakesOnlyCPUNil() throws {
        var value = fixture(); value["processor"] = ["combined_power": 1_000]
        XCTAssertNil(decoder.decode(plistRecord: try plist(value))?.cpu)
    }

    func testMalformedClusterNameIsSkippedWithoutRejectingOtherClusters() throws {
        var value = fixture()
        var processor = value["processor"] as! [String: Any]
        processor["clusters"] = [
            ["name": 42, "cpus": [["cpu": 9, "idle_ratio": 0.1]]],
            ["name": "S-Cluster", "freq_hz": 4_000_000_000.0,
             "cpus": [["cpu": 0, "idle_ratio": 0.5, "freq_hz": 4_000_000_000.0]]],
        ]
        value["processor"] = processor
        XCTAssertEqual(decoder.decode(plistRecord: try plist(value))?.cpu?.fastCores.map(\.id), [0])
    }

    func testMissingGPUIsNil() throws {
        var value = fixture(); value.removeValue(forKey: "gpu")
        XCTAssertNil(decoder.decode(plistRecord: try plist(value))?.gpu)
    }

    func testNonDictionaryGPUIsNil() throws {
        var value = fixture(); value["gpu"] = 10
        XCTAssertNil(decoder.decode(plistRecord: try plist(value))?.gpu)
    }

    func testGPUMissingIdleRatioIsNil() throws {
        var value = fixture(); value["gpu"] = ["freq_hz": 1_000.0]
        XCTAssertNil(decoder.decode(plistRecord: try plist(value))?.gpu)
    }

    func testGPUMissingFrequencyIsNil() throws {
        var value = fixture(); value["gpu"] = ["idle_ratio": 0.5]
        XCTAssertNil(decoder.decode(plistRecord: try plist(value))?.gpu)
    }

    func testMissingNetworkIsNil() throws {
        var value = fixture(); value.removeValue(forKey: "network")
        XCTAssertNil(decoder.decode(plistRecord: try plist(value))?.network)
    }

    func testPartialNetworkIsNil() throws {
        var value = fixture(); value["network"] = ["ibyte_rate": 1.0]
        XCTAssertNil(decoder.decode(plistRecord: try plist(value))?.network)
    }

    func testMissingDiskIsNil() throws {
        var value = fixture(); value.removeValue(forKey: "disk")
        XCTAssertNil(decoder.decode(plistRecord: try plist(value))?.disk)
    }

    func testPartialDiskIsNil() throws {
        var value = fixture(); value["disk"] = ["rbytes_per_s": 1.0]
        XCTAssertNil(decoder.decode(plistRecord: try plist(value))?.disk)
    }

    private func fixture() -> [String: Any] {
        [
            "timestamp": Date(timeIntervalSince1970: 100),
            "processor": [
                "clusters": [[
                    "name": "S-Cluster", "freq_hz": 4_000_000_000.0,
                    "cpus": [["cpu": 0, "idle_ratio": 0.5, "freq_hz": 4_000_000_000.0]],
                ]],
                "cpu_energy": 1_000.0, "gpu_energy": 500.0,
                "ane_energy": 100.0, "combined_power": 5_000.0,
            ],
            "gpu": ["idle_ratio": 0.5, "freq_hz": 1_000.0],
            "thermal_pressure": "Nominal",
            "network": ["ibyte_rate": 1_024.0, "obyte_rate": 2_048.0],
            "disk": ["rbytes_per_s": 4_096.0, "wbytes_per_s": 8_192.0],
        ]
    }

    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
}
