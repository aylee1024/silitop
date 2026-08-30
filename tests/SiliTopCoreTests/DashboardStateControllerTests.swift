import Foundation
import XCTest
@testable import SiliTopCore

final class DashboardStateControllerTests: XCTestCase {
    private let topology = Topology(
        name: "Apple M5 Pro",
        fastLabel: "Super",
        slowLabel: "Performance",
        fastPrefix: "S",
        slowPrefix: "P",
        fastCoreCount: 1,
        slowCoreCount: 1,
        gpuCoreCount: 20
    )

    func testPowerUsesTimestampDeltaAndMaintainsAveragesAndPeaks() {
        var controller = DashboardStateController(topology: topology, intervalSeconds: 2, averageSeconds: 4)
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 104)

        _ = controller.accept(
            sample(energy: 8, timestamp: firstDate),
            memory: .unavailable(reason: "test"),
            temperatures: .unavailable(reason: "test"),
            fans: .unavailable(reason: "test"),
            at: firstDate
        )
        let second = controller.accept(
            sample(energy: 8, timestamp: secondDate),
            memory: .unavailable(reason: "test"),
            temperatures: .unavailable(reason: "test"),
            fans: .unavailable(reason: "test"),
            at: secondDate
        )

        guard case let .fresh(power, _) = second.power else {
            return XCTFail("Expected fresh power")
        }
        XCTAssertEqual(power.cpuWatts, 2, accuracy: 0.001)
        XCTAssertEqual(power.cpuAverageWatts, 3, accuracy: 0.001)
        XCTAssertEqual(power.cpuPeakWatts, 4, accuracy: 0.001)
        XCTAssertEqual(controller.histories.cpuPower, [4, 2])
    }

    func testMissingPowermetricsPanelDoesNotZeroOrVoidOtherPanels() {
        var controller = DashboardStateController(topology: topology, intervalSeconds: 1, averageSeconds: 30)
        var reading = sample(energy: 1, timestamp: Date(timeIntervalSince1970: 100))
        reading = PowerMetricsReading(
            timestamp: reading.timestamp,
            cpu: reading.cpu,
            gpu: reading.gpu,
            thermalPressure: reading.thermalPressure,
            network: nil,
            disk: reading.disk
        )

        let snapshot = controller.accept(
            reading,
            memory: .unavailable(reason: "test"),
            temperatures: .unavailable(reason: "test"),
            fans: .unavailable(reason: "test"),
            at: Date(timeIntervalSince1970: 100)
        )

        guard case .fresh = snapshot.cpu else { return XCTFail("CPU should remain available") }
        guard case .unavailable = snapshot.network else { return XCTFail("Network must be unavailable") }
    }

    func testNativeCollectorLastGoodValueBecomesStaleAfterThreeMissedIntervals() {
        var controller = DashboardStateController(topology: topology, intervalSeconds: 2, averageSeconds: 30)
        let initial = Date(timeIntervalSince1970: 100)
        let readings = [TemperatureReading(name: "PMU tdie0", celsius: 55)]

        _ = controller.accept(
            sample(energy: 1, timestamp: initial),
            memory: .unavailable(reason: "test"),
            temperatures: .value(readings),
            fans: .unavailable(reason: "test"),
            at: initial
        )
        let stale = controller.accept(
            sample(energy: 1, timestamp: initial.addingTimeInterval(6)),
            memory: .unavailable(reason: "test"),
            temperatures: .unavailable(reason: "sensor read failed"),
            fans: .unavailable(reason: "test"),
            at: initial.addingTimeInterval(6)
        )

        XCTAssertEqual(stale.temperatures, .stale(readings, observedAt: initial, reason: "sensor read failed"))
    }

    func testZeroFrequenciesReuseLastKnownCoreAndTierValues() {
        var controller = DashboardStateController(topology: topology, intervalSeconds: 1, averageSeconds: 30)
        let initial = Date(timeIntervalSince1970: 100)
        let first = sample(
            energy: 1,
            timestamp: initial,
            fastCores: [CoreReading(id: 4, activePercent: 100, frequencyMHz: 4_000)],
            slowCores: [CoreReading(id: 8, activePercent: 100, frequencyMHz: 3_000)]
        )
        let second = sample(
            energy: 1,
            timestamp: initial.addingTimeInterval(1),
            fastCores: [CoreReading(id: 4, activePercent: 100, frequencyMHz: 0)],
            slowCores: [CoreReading(id: 9, activePercent: 100, frequencyMHz: 0)]
        )

        _ = controller.accept(first, memory: .unavailable(reason: "test"), temperatures: .unavailable(reason: "test"), fans: .unavailable(reason: "test"), at: initial)
        let snapshot = controller.accept(second, memory: .unavailable(reason: "test"), temperatures: .unavailable(reason: "test"), fans: .unavailable(reason: "test"), at: initial.addingTimeInterval(1))

        guard case let .fresh(cpu, _) = snapshot.cpu else { return XCTFail("Expected CPU") }
        XCTAssertEqual(cpu.fastCores.first?.frequencyMHz, 4_000)
        XCTAssertEqual(cpu.slowCores.first?.frequencyMHz, 3_000)
        XCTAssertEqual(cpu.fastFrequencyMHz, 4_000)
        XCTAssertEqual(cpu.slowFrequencyMHz, 3_000)
    }

    func testFirstFrameZeroFrequencyUsesLaterSiblingInSameTier() {
        var controller = DashboardStateController(topology: topology, intervalSeconds: 1, averageSeconds: 30)
        let observed = Date(timeIntervalSince1970: 100)
        let reading = sample(
            energy: 1,
            timestamp: observed,
            fastCores: [
                CoreReading(id: 0, activePercent: 100, frequencyMHz: 0),
                CoreReading(id: 1, activePercent: 50, frequencyMHz: 3_000),
            ]
        )

        let snapshot = controller.accept(
            reading,
            memory: .unavailable(reason: "test"),
            temperatures: .unavailable(reason: "test"),
            fans: .unavailable(reason: "test"),
            at: observed
        )

        guard case let .fresh(cpu, _) = snapshot.cpu else { return XCTFail("Expected CPU") }
        XCTAssertEqual(cpu.fastCores.map(\.frequencyMHz), [3_000, 3_000])
    }

    func testCurrentSiblingFrequencyBeatsHistoricalTierPeakForNewCore() {
        var controller = DashboardStateController(topology: topology, intervalSeconds: 1, averageSeconds: 30)
        let firstDate = Date(timeIntervalSince1970: 100)
        _ = controller.accept(
            sample(
                energy: 1,
                timestamp: firstDate,
                fastCores: [CoreReading(id: 0, activePercent: 20, frequencyMHz: 4_000)]
            ),
            memory: .unavailable(reason: "test"), temperatures: .unavailable(reason: "test"),
            fans: .unavailable(reason: "test"), at: firstDate
        )
        let secondDate = firstDate.addingTimeInterval(1)
        let snapshot = controller.accept(
            sample(
                energy: 1,
                timestamp: secondDate,
                fastCores: [
                    CoreReading(id: 2, activePercent: 100, frequencyMHz: 0),
                    CoreReading(id: 1, activePercent: 50, frequencyMHz: 2_000),
                ]
            ),
            memory: .unavailable(reason: "test"), temperatures: .unavailable(reason: "test"),
            fans: .unavailable(reason: "test"), at: secondDate
        )

        guard case let .fresh(cpu, _) = snapshot.cpu else { return XCTFail("Expected CPU") }
        XCTAssertEqual(cpu.fastCores.map(\.frequencyMHz), [2_000, 2_000])
    }

    func testTimestampGateRejectsDuplicateAndOutOfOrderRecords() {
        var gate = SampleTimestampGate()
        let first = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(gate.shouldAccept(first))
        XCTAssertFalse(gate.shouldAccept(first))
        XCTAssertFalse(gate.shouldAccept(first.addingTimeInterval(-1)))
        XCTAssertTrue(gate.shouldAccept(first.addingTimeInterval(1)))
        XCTAssertTrue(gate.shouldAccept(nil))
    }

    func testMissingTimestampBreaksDeltaContinuityForNextSample() {
        var controller = DashboardStateController(topology: topology, intervalSeconds: 1, averageSeconds: 30)
        let first = Date(timeIntervalSince1970: 100)
        _ = controller.accept(sample(energy: 1, timestamp: first), memory: .unavailable(reason: "test"), temperatures: .unavailable(reason: "test"), fans: .unavailable(reason: "test"), at: first)
        _ = controller.accept(sample(energy: 1, timestamp: nil), memory: .unavailable(reason: "test"), temperatures: .unavailable(reason: "test"), fans: .unavailable(reason: "test"), at: first.addingTimeInterval(1))
        let result = controller.accept(sample(energy: 1, timestamp: first.addingTimeInterval(2)), memory: .unavailable(reason: "test"), temperatures: .unavailable(reason: "test"), fans: .unavailable(reason: "test"), at: first.addingTimeInterval(2))

        guard case let .fresh(power, _) = result.power else { return XCTFail("Expected fresh power") }
        XCTAssertEqual(power.cpuWatts, 1, accuracy: 0.001)
    }

    func testOverflowingEnergyRateMakesPowerUnavailableInsteadOfZero() {
        var controller = DashboardStateController(topology: topology, intervalSeconds: 1, averageSeconds: 30)
        let first = Date(timeIntervalSince1970: 100)
        _ = controller.accept(
            sample(energy: Double.greatestFiniteMagnitude, timestamp: first),
            memory: .unavailable(reason: "test"), temperatures: .unavailable(reason: "test"),
            fans: .unavailable(reason: "test"), at: first
        )
        let snapshot = controller.accept(
            sample(energy: Double.greatestFiniteMagnitude, timestamp: first),
            memory: .unavailable(reason: "test"), temperatures: .unavailable(reason: "test"),
            fans: .unavailable(reason: "test"), at: first
        )

        guard case .unavailable = snapshot.power else {
            return XCTFail("Overflowing rate must not be displayed as zero")
        }
    }

    private func sample(
        energy: Double,
        timestamp: Date?,
        fastCores: [CoreReading] = [],
        slowCores: [CoreReading] = []
    ) -> PowerMetricsReading {
        PowerMetricsReading(
            timestamp: timestamp,
            cpu: CPUReading(
                fastCores: fastCores, slowCores: slowCores,
                fastActivePercent: 10, slowActivePercent: 20,
                fastFrequencyMHz: 4_000, slowFrequencyMHz: 3_000,
                power: PowerEnergyReading(
                    cpuJoules: energy,
                    gpuJoules: energy / 2,
                    aneJoules: energy / 10,
                    packageWatts: 12
                )
            ),
            gpu: GPUReading(activePercent: 30, frequencyMHz: 1_000),
            thermalPressure: "Nominal",
            network: NetworkReading(inBytesPerSecond: 1_024, outBytesPerSecond: 2_048),
            disk: DiskReading(readBytesPerSecond: 4_096, writeBytesPerSecond: 8_192)
        )
    }
}
