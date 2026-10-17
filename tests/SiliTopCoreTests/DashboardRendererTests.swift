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

        XCTAssertTrue(text.contains("\u{1B}[0;36mz0:49"))
        XCTAssertTrue(text.contains("\u{1B}[0;33mz1:70"))
        XCTAssertTrue(text.contains("\u{1B}[0;31mz2:71"))
        XCTAssertTrue(text.contains("\u{1B}[0;1;32m█"))
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

        XCTAssertTrue(text.hasPrefix("\u{1B}[H\u{1B}[0;1;7;36m"))
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

    func testFullDashboardMatchesTheBoxedCursesLayout() {
        let rendered = DashboardRenderer(ansi: false).render(
            snapshot: completeSnapshot(),
            histories: DashboardHistories.example,
            size: TerminalSize(rows: 60, columns: 100)
        )
        let text = String(decoding: rendered, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertTrue(lines[0].contains("silitop - Apple M5 Pro (6S+12P+20GPU)"))
        XCTAssertTrue(lines.contains { $0.contains("Super:") && $0.contains("Performance:") && $0.contains("83°C") })
        XCTAssertTrue(lines.contains { $0.contains("Fans") && $0.contains("P8") })
        XCTAssertTrue(text.contains("GPU: 75% @ 1000 MHz  72°C"))
        XCTAssertTrue(text.contains("ANE: 1% @ 0.1W"))
        XCTAssertTrue(text.contains("Net: ↓1 KB/s ↑2 KB/s"))
        XCTAssertTrue(text.contains("Disk: R 4 KB/s W 8 KB/s"))
        XCTAssertTrue(text.contains("RAM: 32.0/64.0 GB (50%)"))
        XCTAssertTrue(text.contains("Swap: 0.5/2.0 GB"))
        XCTAssertTrue(text.contains("CPU: 5.0W  GPU: 2.0W  ANE: 0.1W  Total: 10.0W"))
        XCTAssertTrue(text.contains("Throttle:"))
        XCTAssertTrue(text.contains("no"))
        XCTAssertTrue(text.contains("2520r"))
        XCTAssertTrue(text.contains("off"))
        XCTAssertTrue(text.contains("Temperatures"))
        XCTAssertTrue(text.contains("Thermal Pressure:"))
        XCTAssertTrue(text.contains("Nominal"))
        XCTAssertTrue(text.contains("q: quit | silitop"))
        XCTAssertTrue(text.contains("┌"))
        XCTAssertTrue(text.contains("█"))
        XCTAssertFalse(text.contains("Disk I/O"))
        XCTAssertFalse(text.contains("Ctrl-C"))
        XCTAssertFalse(text.contains("—"))
        for line in lines {
            XCTAssertLessThanOrEqual(DisplayWidth.measure(line), 100)
        }
    }

    func testTwentyFourRowTerminalDropsPanelsThatDoNotFit() {
        let text = String(decoding: DashboardRenderer(ansi: false).render(
            snapshot: completeSnapshot(),
            histories: DashboardHistories.example,
            size: TerminalSize(rows: 24, columns: 100)
        ), as: UTF8.self)

        XCTAssertTrue(text.contains("Super:"))
        XCTAssertTrue(text.contains("Fans"))
        XCTAssertTrue(text.contains("ANE:"))
        XCTAssertTrue(text.contains("q: quit | silitop"))
        XCTAssertFalse(text.contains("Disk:"))
        XCTAssertFalse(text.contains("Memory"))
        XCTAssertFalse(text.contains("Temperatures"))
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

        XCTAssertTrue(text.contains("Memory"))
        XCTAssertTrue(text.contains("data unavailable"))
        XCTAssertTrue(text.contains("z0:55"))
        XCTAssertFalse(text.contains("stale"))
    }

    func testWaitingScreenUsesTheOldCopy() {
        let text = String(decoding: DashboardRenderer(ansi: false).waiting(
            size: TerminalSize(rows: 24, columns: 80)
        ), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines[12].trimmingCharacters(in: .whitespaces), "Waiting for powermetrics data...")
        XCTAssertEqual(lines[13].trimmingCharacters(in: .whitespaces), "(requires sudo)")
        XCTAssertFalse(text.contains("—"))
    }

    func testSmallTerminalRendersOnlySizeWarning() {
        let text = String(decoding: DashboardRenderer(ansi: false).render(
            snapshot: completeSnapshot(),
            histories: DashboardHistories(),
            size: TerminalSize(rows: 9, columns: 39)
        ), as: UTF8.self)

        XCTAssertTrue(text.contains("Terminal too small"))
        XCTAssertFalse(text.contains("Disk:"))
        XCTAssertFalse(text.contains("—"))
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

        XCTAssertTrue(text.contains("RAM: 32.0/64.0 GB (50%)"))
        XCTAssertTrue(text.contains("Swap: inactive"))
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

        XCTAssertTrue(text.contains("100%"))
        XCTAssertTrue(text.contains("GPU:"))
    }

    func testIdlePowerUsesTwentyWattFloor() {
        let lines = renderLines(histories: DashboardHistories(
            cpuPower: [0, 10, .nan],
            gpuPower: [1, 1]
        ), rows: 60)
        let spark = powerSpark(lines, label: "CPU ")
        XCTAssertEqual(Array(spark.top.prefix(3)), [" ", " ", " "])
        XCTAssertEqual(Array(spark.bottom.prefix(3)), ["▁", "█", "▁"])
    }

    func testCpuAndGpuSparksUseSeparateVisiblePeaks() {
        let lines = renderLines(histories: DashboardHistories(
            cpuPower: [80, 40],
            gpuPower: [5, 5]
        ), rows: 60)
        let cpu = powerSpark(lines, label: "CPU ")
        let gpu = powerSpark(lines, label: "GPU ")
        XCTAssertEqual(Array(cpu.top.prefix(2)), ["█", " "])
        XCTAssertEqual(Array(cpu.bottom.prefix(2)), ["█", "█"])
        XCTAssertEqual(Array(gpu.top.prefix(2)), [" ", " "])
        XCTAssertEqual(Array(gpu.bottom.prefix(2)), ["▄", "▄"])
    }

    func testScrolledOffSpikeDoesNotRaiseTheVisibleTop() {
        let lines = renderLines(histories: DashboardHistories(
            cpuPower: [80] + Array(repeating: 10, count: 50),
            gpuPower: [1, 1],
            networkIn: [1_000_000] + Array(repeating: 1_000, count: 30),
            networkOut: [1, 1]
        ), rows: 60)
        let cpu = powerSpark(lines, label: "CPU ")
        XCTAssertEqual(Array(cpu.top.prefix(41)), Array(repeating: " ", count: 41))
        XCTAssertEqual(Array(cpu.bottom.prefix(41)), Array(repeating: "█", count: 41))

        guard let net = lines.firstIndex(where: { $0.contains("Net: ↓") }) else {
            XCTFail("missing net title")
            return
        }
        let upper = Array(lines[net + 1])
        let lower = Array(lines[net + 2])
        guard let arrow = upper.firstIndex(of: "↓") else {
            XCTFail("missing download mark")
            return
        }
        let start = arrow + 1
        XCTAssertEqual(Array(upper[start..<(start + 21)]), Array(repeating: "█", count: 21))
        XCTAssertEqual(Array(lower[start..<(start + 21)]), Array(repeating: "█", count: 21))
    }

    func testFortyRowsDropTemperaturesAndFortyOneShowsThem() {
        let histories = DashboardHistories.example
        let forty = String(decoding: DashboardRenderer(ansi: false).render(
            snapshot: completeSnapshot(),
            histories: histories,
            size: TerminalSize(rows: 40, columns: 100)
        ), as: UTF8.self)
        XCTAssertTrue(forty.contains("CPU: 5.0W"))
        XCTAssertTrue(forty.contains("Disk:"))
        XCTAssertTrue(forty.contains("q: quit | silitop"))
        XCTAssertFalse(forty.contains("Temperatures"))
        XCTAssertLessThanOrEqual(forty.split(separator: "\n").count, 40)

        let fortyOne = String(decoding: DashboardRenderer(ansi: false).render(
            snapshot: completeSnapshot(),
            histories: histories,
            size: TerminalSize(rows: 41, columns: 100)
        ), as: UTF8.self)
        XCTAssertTrue(fortyOne.contains("Temperatures"))
        XCTAssertTrue(fortyOne.contains("q: quit | silitop"))
        XCTAssertLessThanOrEqual(fortyOne.split(separator: "\n").count, 41)
    }

    private func renderLines(histories: DashboardHistories, rows: Int) -> [String] {
        let text = String(decoding: DashboardRenderer(ansi: false).render(
            snapshot: completeSnapshot(),
            histories: histories,
            size: TerminalSize(rows: rows, columns: 100)
        ), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func powerSpark(_ lines: [String], label: String) -> (top: [Character], bottom: [Character]) {
        let watts = lines.firstIndex { $0.contains("CPU: 5.0W") }!
        let offset = label == "GPU " ? 5 : 3
        let upper = Array(lines[watts + offset])
        let lower = Array(lines[watts + offset + 1])
        let upperText = String(upper)
        let range = upperText.range(of: label)!
        let start = upperText.distance(from: upperText.startIndex, to: range.upperBound)
        return (Array(upper[start...]), Array(lower[start...]))
    }

    private func completeSnapshot() -> DashboardSnapshot {
        let topology = Topology(
            name: "Apple M5 Pro",
            fastLabel: "Super",
            slowLabel: "Performance",
            fastPrefix: "S",
            slowPrefix: "P",
            fastCoreCount: 6,
            slowCoreCount: 12,
            gpuCoreCount: 20
        )
        let cpu = CPUReading(
            fastCores: (0..<6).map { CoreReading(id: $0, activePercent: 50, frequencyMHz: 4_000) },
            slowCores: (0..<12).map { CoreReading(id: $0 + 6, activePercent: 25, frequencyMHz: 3_000) },
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
            temperatures: .fresh(
                (0..<10).map { TemperatureReading(name: "PMU tdie\($0)", celsius: $0 == 0 ? 83 : 74) }
                    + [
                        TemperatureReading(name: "PMU tdie10", celsius: 72),
                        TemperatureReading(name: "PMU tdie11", celsius: 72),
                        TemperatureReading(name: "NAND CH0 temp", celsius: 33),
                        TemperatureReading(name: "gas gauge battery", celsius: 30),
                    ],
                observedAt: observed
            ),
            fans: .fresh(.fans([
                FanReading(index: 0, rpm: 2_520, maximumRPM: 6_500),
                FanReading(index: 1, rpm: 0, maximumRPM: 6_500),
            ]), observedAt: observed),
            thermalPressure: .fresh("Nominal", observedAt: observed)
        )
    }
}
