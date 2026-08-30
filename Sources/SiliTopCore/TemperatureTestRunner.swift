import Foundation

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum TemperatureTestRunner {
    public static func format(
        _ result: NativeCollectorResult<[TemperatureReading]>
    ) -> CommandResult {
        switch result {
        case let .unavailable(reason):
            return CommandResult(
                exitCode: 2,
                standardOutput: "",
                standardError: "silitop: temperature collector failed: \(reason)\n"
            )
        case let .value(readings) where readings.isEmpty:
            return CommandResult(
                exitCode: 0,
                standardOutput: "No temperature readings (no sensors found).\n",
                standardError: ""
            )
        case let .value(readings):
            let output = readings
                .sorted { $0.name < $1.name }
                .map { String(format: "  %@: %.1f°C\n", $0.name, $0.celsius) }
                .joined()
            return CommandResult(exitCode: 0, standardOutput: output, standardError: "")
        }
    }
}
