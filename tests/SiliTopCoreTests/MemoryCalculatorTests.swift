import XCTest
@testable import SiliTopCore

final class MemoryCalculatorTests: XCTestCase {
    func testM5SnapshotMatchesActivityMonitorFormula() {
        let statistics = VMStatisticsSnapshot(
            anonymousPages: 1_348_827,
            wiredPages: 364_720,
            compressorPages: 2_250_658,
            fileBackedPages: 164_217,
            pageSize: 16_384
        )

        let reading = MemoryCalculator.calculate(
            statistics: statistics,
            totalBytes: 68_719_476_736,
            swap: SwapReading(totalBytes: 51_539_607_552, usedBytes: 49_857_158_349)
        )

        XCTAssertEqual(reading.totalGiB, 64.0)
        XCTAssertEqual(reading.usedGiB, 60.5)
        XCTAssertEqual(reading.percentUsed, 94)
        XCTAssertEqual(reading.appGiB, 20.6)
        XCTAssertEqual(reading.wiredGiB, 5.6)
        XCTAssertEqual(reading.compressedGiB, 34.3)
        XCTAssertEqual(reading.cachedGiB, 2.5)
        XCTAssertEqual(reading.swapTotalGiB, 48.0)
        XCTAssertEqual(reading.swapUsedGiB, 46.4)
    }

    func testPathologicalCountersClampUsedMemoryToTotal() {
        let statistics = VMStatisticsSnapshot(
            anonymousPages: 1_500_000,
            wiredPages: 500_000,
            compressorPages: 2_500_000,
            fileBackedPages: 0,
            pageSize: 16_384
        )

        let reading = MemoryCalculator.calculate(
            statistics: statistics,
            totalBytes: 64 * 1_024 * 1_024 * 1_024,
            swap: nil
        )

        XCTAssertEqual(reading.percentUsed, 100)
        XCTAssertEqual(reading.usedGiB, reading.totalGiB)
        XCTAssertEqual(reading.swapTotalGiB, 0)
        XCTAssertEqual(reading.swapUsedGiB, 0)
    }

    func testInvalidPageSizeReturnsUnavailable() {
        let statistics = VMStatisticsSnapshot(
            anonymousPages: 1,
            wiredPages: 1,
            compressorPages: 1,
            fileBackedPages: 1,
            pageSize: 0
        )

        XCTAssertNil(MemoryCalculator.calculateIfValid(
            statistics: statistics,
            totalBytes: 1_024,
            swap: nil
        ))
    }
}
