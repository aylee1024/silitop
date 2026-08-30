import Foundation
import XCTest
@testable import SiliTopCore

final class SensorContractsTests: XCTestCase {
    func testWarmTemperatureCacheExpiresAnIndividuallyDeadSensor() {
        var cache = HIDTemperatureFreshnessCache()
        cache.record(identity: "live@1", displayName: "live", celsius: 50)
        cache.record(identity: "dead@2", displayName: "dead", celsius: 60)

        for value in 51...53 {
            cache.beginWarmRead()
            cache.record(identity: "live@1", displayName: "live", celsius: Double(value))
        }

        XCTAssertEqual(cache.readings(maximumAge: 2), [
            TemperatureReading(name: "live", celsius: 53),
        ])
    }

    func testReachableClientWithNoServicesIsAConfirmedEmptyReading() {
        XCTAssertEqual(
            HIDDiscoveryOutcome.finish(sawReachableEmptyClient: true, sawAnyServices: false),
            .value([])
        )
        XCTAssertEqual(
            HIDDiscoveryOutcome.finish(sawReachableEmptyClient: false, sawAnyServices: false),
            .unavailable(reason: "no IOHID temperature sensors found")
        )
        XCTAssertEqual(
            HIDDiscoveryOutcome.finish(sawReachableEmptyClient: true, sawAnyServices: true),
            .unavailable(reason: "IOHID temperature sensors unreadable")
        )
    }

    func testTemperatureCacheAgeCoversEntireRoundRobin() {
        XCTAssertEqual(HIDTemperatureCollector.maximumCacheAge(serviceCount: 25), 4)
    }

    func testTemperatureDisplayNamesAreUniqueWithLastReadingWinning() {
        let readings = TemperatureReading.deduplicatedByName([
            TemperatureReading(name: "battery", celsius: 30),
            TemperatureReading(name: "die", celsius: 50),
            TemperatureReading(name: "battery", celsius: 31),
        ])

        XCTAssertEqual(readings, [
            TemperatureReading(name: "battery", celsius: 31),
            TemperatureReading(name: "die", celsius: 50),
        ])
    }

    func testSMCDecoderSupportsFanNumericFormats() {
        XCTAssertEqual(SMCNumericDecoder.decode(type: "fpe2", bytes: [0x1F, 0x40]), 2_000)
        XCTAssertEqual(SMCNumericDecoder.decode(type: "ui16", bytes: [0x19, 0x64]), 6_500)
        XCTAssertEqual(SMCNumericDecoder.decode(type: "ui32", bytes: [0, 0, 0x19, 0x64]), 6_500)

        var float = Float(1_850)
        let bytes = withUnsafeBytes(of: &float) { Array($0) }
        XCTAssertEqual(SMCNumericDecoder.decode(type: "flt ", bytes: bytes), 1_850)
        XCTAssertNil(SMCNumericDecoder.decode(type: "????", bytes: [0, 1, 2, 3]))
    }

    func testSMCFanCountUsesDeclaredIntegerDatatype() {
        XCTAssertEqual(SMCFanCountDecoder.decode(type: "ui8 ", bytes: [2]), 2)
        XCTAssertEqual(SMCFanCountDecoder.decode(type: "ui16", bytes: [0, 2]), 2)
        XCTAssertNil(SMCFanCountDecoder.decode(type: "ui16", bytes: [2]))
        XCTAssertNil(SMCFanCountDecoder.decode(type: "flt ", bytes: [0x7F, 0xC0, 0, 0]))
    }

    func testTemperatureClassificationMatchesExistingDashboardConvention() {
        let temperatures = [
            TemperatureReading(name: "PMU tdie0", celsius: 45.0),
            TemperatureReading(name: "PMU tdie1", celsius: 46.0),
            TemperatureReading(name: "PMU tdie2", celsius: 60.0),
            TemperatureReading(name: "PMU tdie3", celsius: 61.0),
            TemperatureReading(name: "PMU tdev1", celsius: 52.0),
            TemperatureReading(name: "NAND CH0 temp", celsius: 41.0),
            TemperatureReading(name: "gas gauge battery", celsius: 34.0),
            TemperatureReading(name: "PMU tcal", celsius: 99.0),
        ]

        let classified = TemperatureClassifier.classify(temperatures, gpuDieZoneCount: 2)

        XCTAssertEqual(classified.cpuDie.map(\.zone), [0, 1])
        XCTAssertEqual(classified.gpuDie.map(\.zone), [2, 3])
        XCTAssertEqual(classified.other["SoC 1"], 52)
        XCTAssertEqual(classified.other["SSD"], 41)
        XCTAssertEqual(classified.other["Battery"], 34)
        XCTAssertNil(classified.other["PMU tcal"])
    }

    func testLastGoodMetricBecomesVisiblyStaleAfterDeadline() {
        var tracker = LastGoodMetric<Int>(unavailableReason: "not sampled")
        let observed = Date(timeIntervalSince1970: 100)

        tracker.record(42, at: observed)
        tracker.recordFailure(reason: "sensor read failed")

        XCTAssertEqual(tracker.state(at: Date(timeIntervalSince1970: 102), staleAfter: 3), .fresh(42, observedAt: observed))
        XCTAssertEqual(
            tracker.state(at: Date(timeIntervalSince1970: 103), staleAfter: 3),
            .stale(42, observedAt: observed, reason: "sensor read failed")
        )
    }

    func testTrackerWithoutSuccessfulValueIsUnavailable() {
        var tracker = LastGoodMetric<Int>(unavailableReason: "not sampled")
        tracker.recordFailure(reason: "missing API")

        XCTAssertEqual(
            tracker.state(at: Date(), staleAfter: 3),
            .unavailable(reason: "missing API")
        )
    }
}
