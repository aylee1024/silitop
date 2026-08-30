import XCTest
@testable import SiliTopCore

final class CLIOptionsTests: XCTestCase {
    func testDefaultsPreservePublicInterface() throws {
        let result = try CLIParser.parse([])
        XCTAssertEqual(result, .run(CLIOptions()))
    }

    func testAllPublicFlagsParse() throws {
        let result = try CLIParser.parse([
            "--interval", "5", "--color=6", "--avg", "60", "--test-temps",
        ])
        XCTAssertEqual(result, .run(CLIOptions(
            intervalSeconds: 5,
            colorScheme: 6,
            averageSeconds: 60,
            testTemperatures: true
        )))
    }

    func testHelpShortCircuitsWithoutStartingDashboard() throws {
        XCTAssertEqual(try CLIParser.parse(["--help"]), .help)
        XCTAssertEqual(try CLIParser.parse(["-h"]), .help)
    }

    func testInvalidIntervalIsUsageError() {
        assertUsageError(["--interval", "0"], contains: "--interval")
        assertUsageError(["--interval", "-1"], contains: "--interval")
        assertUsageError(["--interval", "later"], contains: "--interval")
        assertUsageError([
            "--interval", String(Int.max), "--avg", String(Int.max),
        ], contains: "too large")
    }

    func testAverageMustCoverAtLeastOneInterval() {
        assertUsageError(["--interval", "5", "--avg", "2"], contains: "--avg")
    }

    func testColorRangeAndUnknownArgumentsAreRejected() {
        assertUsageError(["--color", "7"], contains: "--color")
        assertUsageError(["--wat"], contains: "--wat")
    }

    func testHelpDocumentsEveryStableFlag() {
        let help = CLIParser.helpText
        for flag in ["--interval", "--color", "--avg", "--test-temps"] {
            XCTAssertTrue(help.contains(flag))
        }
    }

    private func assertUsageError(_ arguments: [String], contains text: String) {
        XCTAssertThrowsError(try CLIParser.parse(arguments)) { error in
            guard let error = error as? CLIUsageError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(error.message.contains(text), "\(error.message) does not contain \(text)")
        }
    }
}
