import Foundation
import XCTest
@testable import SiliTopCore

final class DashboardRendererTests: XCTestCase {
    private let observed = Date(timeIntervalSince1970: 1_000)

    func testBarLayoutClampsPercentAndKeepsSuffixSeparate() {
        let layout = HorizontalBar.layout(width: 24, percent: 145, label: "P0 ", suffix: " 100% 960M")

        XCTAssertEqual(layout.percent, 100)
        XCTAssertLessThanOrEqual(layout.labelRange.upperBound, layout.barRange.lowerBound)
        XCTAssertLessThanOrEqual(layout.barRange.upperBound, layout.suffixRange.lowerBound)
        XCTAssertLessThanOrEqual(layout.suffixRange.upperBound, 24)
        XCTAssertEqual(layout.fillWidth + layout.emptyWidth, layout.barRange.count)
    }

    func testRenderedBarNeverOverwritesSuffix() {
        let bar = HorizontalBar.render(width: 30, percent: 145, label: "P0 ", suffix: " 100% 1.0G")

        XCTAssertEqual(DisplayWidth.measure(bar), 30)
        XCTAssertTrue(bar.hasSuffix(" 100% 1.0G"))
        XCTAssertFalse(String(bar.suffix(" 100% 1.0G".count)).contains("█"))
    }

    func testTemperatureBandsMatchReadmeBoundaries() {
        XCTAssertEqual(TemperatureBand.forCelsius(49.9), .cool)
        XCTAssertEqual(TemperatureBand.forCelsius(50), .warm)
        XCTAssertEqual(TemperatureBand.forCelsius(70), .warm)
        XCTAssertEqual(TemperatureBand.forCelsius(70.1), .hot)
        XCTAssertEqual(TemperatureBand.forCelsius(.nan), .warning)
    }

    func testRenderedTemperatureZonesUseInclusiveWarmAndHotANSIColors() {
        var snapshot = completeSnapshot()
        snapshot.temperatures = .fresh([
            TemperatureReading(name: "PMU tdie0", celsius: 49),
            TemperatureReading(name: "PMU tdie1", celsius: 70),
            TemperatureReading(name: "PMU tdie2", celsius: 71),
        ], observedAt: observed)

        let text = String(decoding: DashboardRenderer(ansi: true, colorScheme: 2).render(
            snapshot: snapshot,
            histories: DashboardHistories(),
            size: TerminalSize(rows: 60, columns: 100)
        ), as: UTF8.self)

        XCTAssertTrue(text.contains("\u{1B}[36mz0:49\u{1B}[32m"))
        XCTAssertTrue(text.contains("\u{1B}[33mz1:70\u{1B}[32m"))
        XCTAssertTrue(text.contains("\u{1B}[31mz2:71\u{1B}[32m"))
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertLessThanOrEqual(DisplayWidth.measure(String(line)), 100)
        }
    }

    func testAnsiRendererUsesRequestedLegacyColorSchemeAndResetsIt() {
        let text = String(decoding: DashboardRenderer(ansi: true, colorScheme: 6).render(
            snapshot: completeSnapshot(),
            histories: DashboardHistories(),
            size: TerminalSize(rows: 60, columns: 100)
        ), as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("\u{1B}[H\u{1B}[36m"))
        XCTAssertTrue(text.contains("\u{1B}[J"))
        XCTAssertTrue(text.hasSuffix("\u{1B}[0m"))
    }

    func testCoreLabelsAreOneBasedWithinEachTierNotHardwareIDs() {
        var snapshot = completeSnapshot()
        if case let .fresh(cpu, observedAt) = snapshot.cpu {
            var changed = cpu
            changed.slowCores = [CoreReading(id: 6, activePercent: 25, frequencyMHz: 3_000)]
            snapshot.cpu = .fresh(changed, observedAt: observedAt)
        }

        let text = String(decoding: DashboardRenderer(ansi: false).render(
            snapshot: snapshot,
            histories: DashboardHistories(),
            size: TerminalSize(rows: 60, columns: 100)
        ), as: UTF8.self)

        XCTAssertTrue(text.contains("P1 "))
        XCTAssertFalse(text.contains("P6 "))
    }

    func testFullDashboardContainsEveryExistingPanelAndFitsWidth() {
        let rendered = DashboardRenderer(ansi: false).render(
            snapshot: completeSnapshot(),
            histories: DashboardHistories.example,
            size: TerminalSize(rows: 60, columns: 100)
        )
        let text = String(decoding: rendered, as: UTF8.self)

        for heading in ["silitop", "Super", "Performance", "GPU", "ANE", "Fans", "Power", "Network", "Disk I/O", "Memory", "Temperatures", "Thermal Pressure", "q: quit"] {
            XCTAssertTrue(text.contains(heading), "Missing heading \(heading) in:\n\(text)")
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertLessThanOrEqual(DisplayWidth.measure(String(line)), 100)
        }
    }

    func testStandardTwentyFourRowTerminalKeepsEveryPanelVisible() {
        let text = String(decoding: DashboardRenderer(ansi: false).render(
            snapshot: completeSnapshot(),
            histories: DashboardHistories.example,
            size: TerminalSize(rows: 24, columns: 100)
        ), as: UTF8.self)

        for heading in ["CPU", "GPU", "ANE", "Fans", "Power", "Network", "Disk I/O", "Memory", "Temperatures", "Thermal Pressure", "q: quit"] {
            XCTAssertTrue(text.contains(heading), "Missing \(heading) in compact frame:\n\(text)")
        }
        XCTAssertLessThanOrEqual(text.split(separator: "\n").count, 24)
    }

    func testTemperaturePanelClassifiesDieZonesAndHidesCalibrationSensor() {
        var snapshot = completeSnapshot()
        snapshot.temperatures = .fresh([
            TemperatureReading(name: "PMU tcal", celsius: 99),
            TemperatureReading(name: "PMU tdie0", celsius: 60),
            TemperatureReading(name: "PMU tdie1", celsius: 70),
            TemperatureReading(name: "PMU tdie2", celsius: 71),
            TemperatureReading(name: "NAND CH0 temp", celsius: 40),
        ], observedAt: observed)

        let text = String(decoding: DashboardRenderer(ansi: false).render(
            snapshot: snapshot,
            histories: DashboardHistories(),
            size: TerminalSize(rows: 60, columns: 100)
        ), as: UTF8.self)

        XCTAssertTrue(text.contains("CPU Die"))
        XCTAssertTrue(text.contains("GPU Die"))
        XCTAssertTrue(text.contains("SSD"))
        XCTAssertFalse(text.contains("tcal"))
    }

    func testUnavailableAndStaleStatesAreVisible() {
        var snapshot = completeSnapshot()
        snapshot.memory = .unavailable(reason: "host statistics failed")
        snapshot.temperatures = .stale(
            [TemperatureReading(name: "PMU tdie0", celsius: 55)],
            observedAt: observed.addingTimeInterval(-10),
            reason: "sensor read failed"
        )

        let text = String(decoding: DashboardRenderer(ansi: false).render(
            snapshot: snapshot,
            histories: DashboardHistories(),
            size: TerminalSize(rows: 60, columns: 100)
        ), as: UTF8.self)

        XCTAssertTrue(text.contains("Memory: unavailable"))
        XCTAssertTrue(text.contains("stale 10s"))
    }

    func testSmallTerminalRendersOnlySizeWarning() {
        let text = String(decoding: DashboardRenderer(ansi: false).render(
            snapshot: completeSnapshot(),
            histories: DashboardHistories(),
            size: TerminalSize(rows: 9, columns: 39)
        ), as: UTF8.self)

        XCTAssertTrue(text.contains("Terminal too small"))
        XCTAssertFalse(text.contains("Disk I/O"))
    }

    func testMissingSwapRendersUnavailableWithoutVoidingMemoryPanel() {
        var snapshot = completeSnapshot()
        snapshot.memory = .fresh(MemoryReading(
            totalGiB: 64, usedGiB: 32, freeGiB: 32, percentUsed: 50,
            wiredGiB: 5, compressedGiB: 4, appGiB: 23, cachedGiB: 8,
            swapTotalGiB: nil, swapUsedGiB: nil
        ), observedAt: observed)

        let text = String(decoding: DashboardRenderer(ansi: false).render(
            snapshot: snapshot,
            histories: DashboardHistories(),
            size: TerminalSize(rows: 60, columns: 160)
        ), as: UTF8.self)

        XCTAssertTrue(text.contains("Memory  32.0/64.0 GB"))
        XCTAssertTrue(text.contains("Swap unavailable"))
    }

    func testHugeFinitePowerDoesNotTrapRendererIntegerConversions() {
        var snapshot = completeSnapshot()
        snapshot.power = .fresh(PowerReading(
            cpuWatts: 1e300, gpuWatts: 1e300, aneWatts: 1e300, packageWatts: 1e300,
            cpuAverageWatts: 1e300, gpuAverageWatts: 1e300,
            cpuPeakWatts: 1e300, gpuPeakWatts: 1e300, packagePeakWatts: 1e300
        ), observedAt: observed)

        let text = String(decoding: DashboardRenderer(ansi: false).render(
            snapshot: snapshot,
            histories: DashboardHistories(cpuPower: [1e300]),
            size: TerminalSize(rows: 60, columns: 120)
        ), as: UTF8.self)

        XCTAssertTrue(text.contains("ANE"))
        XCTAssertTrue(text.contains("100%"))
    }

    private func completeSnapshot() -> DashboardSnapshot {
        let topology = Topology(
            name: "Apple M5 Pro",
            fastLabel: "Super",
            slowLabel: "Performance",
            fastPrefix: "S",
            slowPrefix: "P",
            fastCoreCount: 1,
            slowCoreCount: 1,
            gpuCoreCount: 20
        )
        let cpu = CPUReading(
            fastCores: [CoreReading(id: 0, activePercent: 50, frequencyMHz: 4_000)],
            slowCores: [CoreReading(id: 1, activePercent: 25, frequencyMHz: 3_000)],
            fastActivePercent: 50,
            slowActivePercent: 25,
            fastFrequencyMHz: 4_000,
            slowFrequencyMHz: 3_000,
            power: PowerEnergyReading(cpuJoules: 5, gpuJoules: 2, aneJoules: 0.1, packageWatts: 10)
        )
        return DashboardSnapshot(
            observedAt: observed,
            topology: topology,
            cpu: .fresh(cpu, observedAt: observed),
            gpu: .fresh(GPUReading(activePercent: 75, frequencyMHz: 1_000), observedAt: observed),
            power: .fresh(PowerReading(cpuWatts: 5, gpuWatts: 2, aneWatts: 0.1, packageWatts: 10, cpuAverageWatts: 4.5, gpuAverageWatts: 1.5, cpuPeakWatts: 8, gpuPeakWatts: 4, packagePeakWatts: 12), observedAt: observed),
            network: .fresh(NetworkReading(inBytesPerSecond: 1_024, outBytesPerSecond: 2_048), observedAt: observed),
            disk: .fresh(DiskReading(readBytesPerSecond: 4_096, writeBytesPerSecond: 8_192), observedAt: observed),
            memory: .fresh(MemoryReading(totalGiB: 64, usedGiB: 32, freeGiB: 32, percentUsed: 50, wiredGiB: 5, compressedGiB: 4, appGiB: 23, cachedGiB: 8, swapTotalGiB: 2, swapUsedGiB: 0.5), observedAt: observed),
            temperatures: .fresh([
                TemperatureReading(name: "PMU tdie0", celsius: 55),
                TemperatureReading(name: "PMU tdie1", celsius: 60),
                TemperatureReading(name: "PMU tdie2", celsius: 65),
                TemperatureReading(name: "NAND CH0 temp", celsius: 41),
            ], observedAt: observed),
            fans: .fresh(.fans([FanReading(index: 0, rpm: 2_000, maximumRPM: 6_500)]), observedAt: observed),
            thermalPressure: .fresh("Nominal", observedAt: observed)
        )
    }
}
