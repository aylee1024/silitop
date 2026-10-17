import Foundation
import XCTest

final class InstallerContractsTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var script: String {
        get throws {
            return try String(contentsOf: root.appendingPathComponent("install.sh"), encoding: .utf8)
        }
    }

    func testBuildsAndStripsOneReleaseExecutableWithoutPythonOrHelpers() throws {
        let script = try script
        XCTAssertTrue(script.contains("swift build -c release --product silitop"))
        XCTAssertTrue(script.contains("--build-path \"${BUILD_PATH}\""))
        XCTAssertTrue(script.contains("rm -rf \"${BUILD_PATH}\""))
        XCTAssertTrue(script.contains("strip \"${BINARY}\""))
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

    func testInstallerActuallyMigratesAndUninstallsInIsolatedDirectory() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("silitop-installer-\(UUID().uuidString)")
        let commands = temporary.appendingPathComponent("commands")
        let installDirectory = temporary.appendingPathComponent("bin")
        let buildDirectory = temporary.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let native = Data("native-silitop".utf8)
        let builtBinary = buildDirectory.appendingPathComponent("silitop")
        try native.write(to: builtBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: builtBinary.path)
        for legacy in ["silitop", "silitop-temps", "silitop-fans"] {
            let path = installDirectory.appendingPathComponent(legacy)
            try Data("legacy".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }

        try writeExecutable("""
        #!/bin/bash
        if [[ " $* " == *" --show-bin-path "* ]]; then printf '%s\\n' "$MOCK_BIN_DIR"; fi
        """, named: "swift", in: commands)
        try writeExecutable("""
        #!/bin/bash
        [[ "${1:-}" == "-m" ]] && printf 'arm64\\n' || printf 'Darwin\\n'
        """, named: "uname", in: commands)
        try writeExecutable("#!/bin/bash\nprintf '26.0\\n'\n", named: "sw_vers", in: commands)
        try writeExecutable("#!/bin/bash\nexit 0\n", named: "strip", in: commands)
        try writeExecutable("#!/bin/bash\nexec \"$@\"\n", named: "sudo", in: commands)
        try writeExecutable("""
        #!/bin/bash
        mode=0755
        files=()
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -o|-g) shift 2 ;;
            -m) mode="$2"; shift 2 ;;
            *) files+=("$1"); shift ;;
          esac
        done
        /usr/bin/install -m "$mode" "${files[0]}" "${files[1]}"
        """, named: "install", in: commands)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(commands.path):\(installDirectory.path):/usr/bin:/bin"
        environment["MOCK_BIN_DIR"] = buildDirectory.path
        environment["SILITOP_INSTALL_DIR"] = installDirectory.path

        XCTAssertEqual(try runInstaller(arguments: [], environment: environment), 0)
        XCTAssertEqual(try Data(contentsOf: installDirectory.appendingPathComponent("silitop")), native)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installDirectory.appendingPathComponent("silitop-temps").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installDirectory.appendingPathComponent("silitop-fans").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: installDirectory.path).contains { $0.hasPrefix(".silitop-install") })

        XCTAssertEqual(try runInstaller(arguments: ["--uninstall"], environment: environment), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installDirectory.appendingPathComponent("silitop").path))
    }

    private func writeExecutable(_ contents: String, named name: String, in directory: URL) throws {
        let path = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    private func runInstaller(arguments: [String], environment: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("install.sh").path] + arguments
        process.currentDirectoryURL = root
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
