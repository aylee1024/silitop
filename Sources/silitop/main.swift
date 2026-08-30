import Darwin
import Foundation
import SiliTopCore

private func write(_ text: String, to handle: FileHandle) {
    if let data = text.data(using: .utf8) {
        try? handle.write(contentsOf: data)
    }
}

let parsed: CLIParseResult
do {
    parsed = try CLIParser.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIUsageError {
    write("silitop: error: \(error.message)\n\n\(CLIParser.helpText)\n", to: .standardError)
    exit(2)
} catch {
    write("silitop: error: \(error)\n", to: .standardError)
    exit(2)
}

switch parsed {
case .help:
    write(CLIParser.helpText + "\n", to: .standardOutput)
    exit(0)

case let .run(options) where options.testTemperatures:
    let result = TemperatureTestRunner.format(HIDTemperatureCollector().read())
    write(result.standardOutput, to: .standardOutput)
    write(result.standardError, to: .standardError)
    exit(result.exitCode)

case let .run(options):
    guard geteuid() == 0 else {
        write("silitop requires root privileges for powermetrics.\nRun with: sudo silitop\n", to: .standardError)
        exit(1)
    }
    do {
        try DashboardApplication(options: options).run()
        exit(0)
    } catch {
        write("silitop: \(error)\n", to: .standardError)
        exit(1)
    }
}
