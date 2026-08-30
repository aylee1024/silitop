import XCTest
@testable import SiliTopCore

final class TopologyGenerationFixturesTests: XCTestCase {
    func testM1Fixture() { assertTopology("Apple M1", "Performance", "Efficiency", 4, 4) }
    func testM2ProFixture() { assertTopology("Apple M2 Pro", "Performance", "Efficiency", 8, 4) }
    func testM3MaxFixture() { assertTopology("Apple M3 Max", "Performance", "Efficiency", 12, 4) }
    func testM4MaxFixture() { assertTopology("Apple M4 Max", "Performance", "Efficiency", 12, 4) }
    func testM5ProFixture() { assertTopology("Apple M5 Pro", "Super", "Performance", 6, 12) }

    private func assertTopology(
        _ chip: String,
        _ fast: String,
        _ slow: String,
        _ fastCount: UInt64,
        _ slowCount: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let strings = [
            "machdep.cpu.brand_string": chip,
            "hw.perflevel0.name": fast,
            "hw.perflevel1.name": slow,
        ]
        let integers = [
            "hw.perflevel0.physicalcpu_max": fastCount,
            "hw.perflevel1.physicalcpu_max": slowCount,
        ]
        let topology = TopologyDetector(
            sysctl: { strings[$0] },
            integerSysctl: { integers[$0] }
        ).detect()
        XCTAssertEqual(topology.name, chip, file: file, line: line)
        XCTAssertEqual(topology.fastLabel, fast, file: file, line: line)
        XCTAssertEqual(topology.slowLabel, slow, file: file, line: line)
        XCTAssertEqual(topology.fastCoreCount, Int(fastCount), file: file, line: line)
        XCTAssertEqual(topology.slowCoreCount, Int(slowCount), file: file, line: line)
    }
}
