import Foundation
import XCTest

final class ReleaseConfigurationTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPackageDeclaresSwift57AndMacOS13() throws {
        let package = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(package.contains("swift-tools-version: 5.7"))
        XCTAssertTrue(package.contains(".macOS(.v13)"))
        XCTAssertTrue(package.contains("swiftLanguageVersions: [.v5]"))
        XCTAssertTrue(package.contains("-Osize"))
    }

    func testCIExercisesTestsReleaseShellAndDeploymentTarget() throws {
        let workflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/test.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(workflow.contains("swift test"))
        XCTAssertTrue(workflow.contains("swift build -c release --product silitop"))
        XCTAssertTrue(workflow.contains("bash -n install.sh"))
        XCTAssertTrue(workflow.contains("vtool -show-build"))
        XCTAssertTrue(workflow.contains("13.0"))
        XCTAssertTrue(workflow.contains("strip \"${binary}\""))
        XCTAssertTrue(workflow.contains("400150"))
    }
}
