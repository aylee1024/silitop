import Foundation
import XCTest

final class InstallerContractsTests: XCTestCase {
    private var script: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("install.sh"), encoding: .utf8)
        }
    }

    func testBuildsAndStripsOneReleaseExecutableWithoutPythonOrHelpers() throws {
        let script = try script
        XCTAssertTrue(script.contains("swift build -c release --product silitop"))
        XCTAssertTrue(script.contains("strip -x"))
        XCTAssertFalse(script.contains("python3"))
        XCTAssertFalse(script.contains("swiftc -O silitop-temps.swift"))
        XCTAssertFalse(script.contains("swiftc -O silitop-fans.swift"))
    }

    func testInstallationUsesAtomicRenameAndRootWheelMode() throws {
        let script = try script
        XCTAssertTrue(script.contains("install -o root -g wheel -m 0755"))
        XCTAssertTrue(script.contains("mv -f"))
        XCTAssertTrue(script.contains(".silitop-install"))
    }

    func testUpgradeAndUninstallRemoveLegacyHelpers() throws {
        let script = try script
        XCTAssertGreaterThanOrEqual(script.components(separatedBy: "silitop-temps").count - 1, 2)
        XCTAssertGreaterThanOrEqual(script.components(separatedBy: "silitop-fans").count - 1, 2)
        XCTAssertTrue(script.contains("--uninstall"))
    }

    func testPathShadowProtectionAndSudoInvocationGuardRemain() throws {
        let script = try script
        XCTAssertTrue(script.contains("command -v silitop"))
        XCTAssertTrue(script.contains("EUID"))
        XCTAssertTrue(script.contains("do not run install.sh under sudo"))
    }
}
