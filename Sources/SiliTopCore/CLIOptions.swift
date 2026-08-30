import Foundation

public struct CLIOptions: Equatable, Sendable {
    public var intervalSeconds: Int
    public var colorScheme: Int
    public var averageSeconds: Int
    public var testTemperatures: Bool

    public init(
        intervalSeconds: Int = 1,
        colorScheme: Int = 2,
        averageSeconds: Int = 30,
        testTemperatures: Bool = false
    ) {
        self.intervalSeconds = intervalSeconds
        self.colorScheme = colorScheme
        self.averageSeconds = averageSeconds
        self.testTemperatures = testTemperatures
    }
}

public enum CLIParseResult: Equatable {
    case run(CLIOptions)
    case help
}

public struct CLIUsageError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

public enum CLIParser {
    public static let helpText = """
    Usage: silitop [--interval SECONDS] [--color 0-6] [--avg SECONDS] [--test-temps]

    Apple Silicon performance monitor with per-core display.

      --interval SECONDS  Sampling interval (default: 1; minimum: 1)
      --color 0-6         Color scheme (default: 2/green)
      --avg SECONDS       Power averaging window (default: 30)
      --test-temps        Print temperature sensor readings and exit
      -h, --help          Show this help
    """

    public static func parse(_ arguments: [String]) throws -> CLIParseResult {
        var options = CLIOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" { return .help }
            if argument == "--test-temps" {
                options.testTemperatures = true
                index += 1
                continue
            }

            let pair = splitOption(argument)
            let option = pair.name
            guard ["--interval", "--color", "--avg"].contains(option) else {
                throw CLIUsageError("unrecognized argument: \(argument)")
            }

            let rawValue: String
            if let inline = pair.value {
                rawValue = inline
            } else {
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw CLIUsageError("\(option) requires an integer value")
                }
                rawValue = arguments[index]
            }
            guard let value = Int(rawValue) else {
                throw CLIUsageError("\(option) requires an integer value")
            }

            switch option {
            case "--interval": options.intervalSeconds = value
            case "--color": options.colorScheme = value
            case "--avg": options.averageSeconds = value
            default: break
            }
            index += 1
        }

        guard options.intervalSeconds >= 1 else {
            throw CLIUsageError("--interval must be >= 1 (seconds)")
        }
        guard (0...6).contains(options.colorScheme) else {
            throw CLIUsageError("--color must be between 0 and 6")
        }
        guard options.averageSeconds >= options.intervalSeconds else {
            throw CLIUsageError("--avg (\(options.averageSeconds)) must be >= --interval (\(options.intervalSeconds))")
        }
        return .run(options)
    }

    private static func splitOption(_ argument: String) -> (name: String, value: String?) {
        guard let equals = argument.firstIndex(of: "=") else {
            return (argument, nil)
        }
        return (
            String(argument[..<equals]),
            String(argument[argument.index(after: equals)...])
        )
    }
}
