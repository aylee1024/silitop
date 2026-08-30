import Foundation
import XCTest
@testable import SiliTopCore

final class AdditionalParityContractsTests: XCTestCase {
    func testCLIRejectsMissingOptionValues() {
        for flag in ["--interval", "--color", "--avg"] {
            XCTAssertThrowsError(try CLIParser.parse([flag]))
        }
    }

    func testCLIRejectsEmptyInlineInteger() {
        XCTAssertThrowsError(try CLIParser.parse(["--interval="]))
    }

    func testFramerEmitsSeveralRecordsFromOneRead() {
        var framer = NULRecordFramer()
        XCTAssertEqual(framer.push(Data("one\0two\0three\0".utf8)), [
            Data("one".utf8), Data("two".utf8), Data("three".utf8),
        ])
    }

    func testFramerIgnoresEmptySeparators() {
        var framer = NULRecordFramer()
        XCTAssertEqual(framer.push(Data("\0ok\0\0".utf8)), [Data("ok".utf8)])
    }

    func testMemoryPanelSurvivesMissingSwap() {
        let reading = MemoryCalculator.calculate(
            statistics: VMStatisticsSnapshot(
                anonymousPages: 10_000, wiredPages: 10_000, compressorPages: 10_000,
                fileBackedPages: 10_000, pageSize: 16_384
            ),
            totalBytes: 16_384 * 100_000,
            swap: nil
        )
        XCTAssertEqual(reading.swapTotalGiB, 0)
        XCTAssertEqual(reading.swapUsedGiB, 0)
        XCTAssertGreaterThan(reading.usedGiB, 0)
    }

    func testLastGoodMetricRemainsFreshBeforeThreeIntervals() {
        var metric = LastGoodMetric<Int>(unavailableReason: "none")
        let start = Date(timeIntervalSince1970: 100)
        metric.record(7, at: start)
        metric.recordFailure(reason: "miss")
        XCTAssertEqual(metric.state(at: start.addingTimeInterval(2), staleAfter: 3), .fresh(7, observedAt: start))
    }

    func testZeroWidthBarIsSafe() {
        let bar = HorizontalBar.render(width: 0, percent: 50, label: "P1", suffix: " 50%")
        XCTAssertEqual(bar, "")
    }

    func testNegativeAndNaNStylePercentInputsClampAtTypedBoundary() {
        XCTAssertEqual(HorizontalBar.layout(width: 10, percent: -1, label: "", suffix: "").percent, 0)
        XCTAssertEqual(HorizontalBar.layout(width: 10, percent: 101, label: "", suffix: "").percent, 100)
    }

    func testSpawnFailureCarriesExecutableAndPOSIXReason() {
        XCTAssertThrowsError(try SpawnedChild.spawn(executable: "/definitely/missing/silitop", arguments: [])) { error in
            XCTAssertTrue(String(describing: error).contains("/definitely/missing/silitop"))
        }
    }

    func testCorruptProfilerOutputLeavesTopologyUntouched() {
        let topology = Topology(
            name: "Apple M5 Pro", fastLabel: "Super", slowLabel: "Performance",
            fastPrefix: "S", slowPrefix: "P", fastCoreCount: 6,
            slowCoreCount: 12, gpuCoreCount: nil
        )
        XCTAssertEqual(SystemProfilerTopologyMerger.merge(data: Data("bad".utf8), into: topology), topology)
    }

    func testTdevTemperaturesRemainAvailableAsSoCHighlights() {
        let classified = TemperatureClassifier.classify([
            TemperatureReading(name: "PMU tdev3", celsius: 44),
        ])
        XCTAssertEqual(classified.other["SoC 3"], 44)
    }

    func testByteTailHandlesInputLargerThanCapacityInOneWrite() {
        var tail = ByteTail(capacity: 4)
        tail.append(Data("123456".utf8))
        XCTAssertEqual(tail.string, "3456")
    }
}
