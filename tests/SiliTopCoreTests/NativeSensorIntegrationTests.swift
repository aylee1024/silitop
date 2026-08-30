import Foundation
import XCTest
@testable import SiliTopCore

final class NativeSensorIntegrationTests: XCTestCase {
    func testHIDCollectorReadsFiniteTemperaturesOnAppleSiliconHost() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Hosted runners do not expose physical IOHID temperature sensors")
        }

        let result = HIDTemperatureCollector().read()

        guard case let .value(readings) = result else {
            return XCTFail("Expected local IOHID temperature readings, got \(result)")
        }
        XCTAssertFalse(readings.isEmpty)
        XCTAssertTrue(readings.allSatisfy { $0.celsius.isFinite && $0.celsius > 0 && $0.celsius < 150 })
    }

    func testWarmHIDCollectorP99IsBelowTwentyMilliseconds() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Hosted runners do not expose physical IOHID temperature sensors")
        }
        let collector = HIDTemperatureCollector()
        guard case .value = collector.read() else {
            throw XCTSkip("No physical IOHID sensors")
        }
        var durations: [TimeInterval] = []
        for _ in 0..<100 {
            let start = Date()
            guard case .value = collector.read() else { return XCTFail("Warm collector failed") }
            durations.append(Date().timeIntervalSince(start))
        }
        durations.sort()
        let p99 = durations[98]
        XCTAssertLessThan(p99, 0.020, "warm IOHID p99 was \(p99 * 1_000) ms")
    }

    func testSMCCollectorReadsFansOrConfirmedFanlessOnPhysicalHost() throws {
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Hosted runners do not expose AppleSMC")
        }

        let result = AppleSMCFanCollector().read()

        switch result {
        case let .value(.fans(fans)):
            XCTAssertFalse(fans.isEmpty)
            XCTAssertTrue(fans.allSatisfy { $0.rpm >= 0 && $0.maximumRPM > 0 })
        case .value(.fanless):
            break
        case let .unavailable(reason):
            XCTFail("Expected AppleSMC fans or fanless state, got \(reason)")
        }
    }
}
