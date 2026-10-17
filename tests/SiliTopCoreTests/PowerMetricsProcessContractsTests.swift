import Darwin
import Foundation
import XCTest
@testable import SiliTopCore

final class PowerMetricsProcessContractsTests: XCTestCase {
    func testFullInvocationStreamsPlistWithRequestedIntervalAndNicePriority() {
        let command = PowerMetricsCommand(intervalSeconds: 5, samplerSet: .full)

        XCTAssertEqual(command.executable, "/usr/bin/nice")
        XCTAssertEqual(command.arguments, [
            "-n", "10", "/usr/bin/powermetrics",
            "-b", "0", "-f", "plist", "-o", "-", "-i", "5000",
            "--samplers", "cpu_power,gpu_power,thermal,network,disk",
            "--handle-invalid-values",
        ])
    }

    func testConfiguredSamplersAreSupportedByInstalledPowermetrics() throws {
        let child = try SpawnedChild.spawn(executable: "/usr/bin/powermetrics", arguments: ["--help"])
        defer { child.cleanup() }
        var help = Data()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, child.reapIfExited() == nil {
            help.append(child.readStdout())
            help.append(child.readStderr())
            usleep(1_000)
        }
        help.append(child.readStdout())
        help.append(child.readStderr())
        let text = String(decoding: help, as: UTF8.self)

        for samplerSet in [PowerMetricsSamplerSet.full, .essential] {
            for sampler in samplerSet.value.split(separator: ",") {
                XCTAssertTrue(text.contains("    \(sampler) "), "Unsupported sampler: \(sampler)")
            }
        }
        XCTAssertTrue(text.contains("--handle-invalid-values"))
    }

    func testEssentialRetryDropsOptionalSamplerSections() {
        let command = PowerMetricsCommand(intervalSeconds: 1, samplerSet: .essential)
        XCTAssertEqual(
            Array(command.arguments.suffix(3)),
            ["--samplers", "cpu_power,gpu_power,thermal", "--handle-invalid-values"]
        )
    }

    func testStallDeadlineIsAtLeastThreeSecondsAndThreeIntervals() {
        XCTAssertEqual(PowerMetricsCommand.stallTimeout(intervalSeconds: 1), 3)
        XCTAssertEqual(PowerMetricsCommand.stallTimeout(intervalSeconds: 5), 15)
        XCTAssertTrue(PowerMetricsCommand.stallTimeout(intervalSeconds: Int.max).isFinite)
        XCTAssertFalse(PowerMetricsCommand(intervalSeconds: Int.max, samplerSet: .full).arguments.isEmpty)
    }

    func testStderrTailKeepsOnlyLastEightKiBAcrossFragmentedWrites() {
        var tail = ByteTail(capacity: 8 * 1_024)
        tail.append(Data(repeating: 65, count: 8_000))
        tail.append(Data(repeating: 66, count: 1_000))

        XCTAssertEqual(tail.data.count, 8 * 1_024)
        XCTAssertEqual(tail.data.suffix(1), Data([66]))
        XCTAssertEqual(tail.data.prefix(1), Data([65]))
    }
}
