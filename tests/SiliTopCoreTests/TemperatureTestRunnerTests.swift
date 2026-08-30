import XCTest
@testable import SiliTopCore

final class TemperatureTestRunnerTests: XCTestCase {
    func testReadingsAreStableSortedAndSuccessful() {
        let result = TemperatureTestRunner.format(.value([
            TemperatureReading(name: "z sensor", celsius: 50),
            TemperatureReading(name: "a sensor", celsius: 40.25),
        ]))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(result.standardOutput, "  a sensor: 40.2°C\n  z sensor: 50.0°C\n")
    }

    func testNoSensorsIsAValidTemperatureTest() {
        let result = TemperatureTestRunner.format(.value([]))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "No temperature readings (no sensors found).\n")
    }

    func testBrokenCollectorUsesDocumentedExitTwo() {
        let result = TemperatureTestRunner.format(.unavailable(reason: "private symbols missing"))
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.standardError.contains("temperature collector failed"))
        XCTAssertTrue(result.standardError.contains("private symbols missing"))
        XCTAssertEqual(result.standardOutput, "")
    }
}
