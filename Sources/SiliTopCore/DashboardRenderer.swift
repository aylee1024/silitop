import Darwin
import Foundation

public enum DisplayWidth {
    public static func measure(_ text: String) -> Int {
        var width = 0
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar.value == 0x1B {
                if let next = iterator.next(), next.value == 0x5B {
                    while let code = iterator.next() {
                        if (0x40...0x7E).contains(code.value) { break }
                    }
                }
                continue
            }
            let measured = Int(wcwidth(wchar_t(scalar.value)))
            if measured >= 0 {
                width += measured
            } else if !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.nonBaseCharacters.contains(scalar) {
                // C/POSIX locales may not classify Unicode bar glyphs even though
                // modern macOS terminals render them as a single cell.
                width += 1
            }
        }
        return width
    }

    public static func clip(_ text: String, to maximumWidth: Int) -> String {
        guard maximumWidth > 0 else { return "" }
        var result = ""
        var width = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\u{1B}" {
                let escapeStart = index
                index = text.index(after: index)
                if index < text.endIndex, text[index] == "[" {
                    index = text.index(after: index)
                    while index < text.endIndex {
                        let scalar = text[index].unicodeScalars.first?.value ?? 0
                        index = text.index(after: index)
                        if (0x40...0x7E).contains(scalar) { break }
                    }
                }
                result.append(contentsOf: text[escapeStart..<index])
                continue
            }
            let characterWidth = measure(String(character))
            if width + characterWidth > maximumWidth { break }
            result.append(character)
            width += characterWidth
            index = text.index(after: index)
        }
        return result
    }

    public static func fit(_ text: String, to width: Int) -> String {
        let clipped = clip(text, to: max(0, width))
        return clipped + String(repeating: " ", count: max(0, width - measure(clipped)))
    }
}

public struct HorizontalBarLayout: Equatable {
    public let percent: Int
    public let labelRange: Range<Int>
    public let barRange: Range<Int>
    public let suffixRange: Range<Int>
    public let fillWidth: Int
    public let emptyWidth: Int
}

public enum HorizontalBar {
    public static func layout(width: Int, percent: Int, label: String, suffix: String) -> HorizontalBarLayout {
        let available = max(0, width)
        let suffixWidth = min(available, DisplayWidth.measure(suffix))
        let suffixStart = available - suffixWidth
        let labelWidth = min(suffixStart, DisplayWidth.measure(label))
        let barWidth = max(0, suffixStart - labelWidth)
        let clampedPercent = min(100, max(0, percent))
        let fill = Int((Double(barWidth) * Double(clampedPercent) / 100).rounded())
        return HorizontalBarLayout(
            percent: clampedPercent,
            labelRange: 0..<labelWidth,
            barRange: labelWidth..<suffixStart,
            suffixRange: suffixStart..<available,
            fillWidth: fill,
            emptyWidth: barWidth - fill
        )
    }

    public static func render(width: Int, percent: Int, label: String, suffix: String) -> String {
        let result = layout(width: width, percent: percent, label: label, suffix: suffix)
        let renderedLabel = DisplayWidth.fit(label, to: result.labelRange.count)
        let renderedSuffix = DisplayWidth.fit(suffix, to: result.suffixRange.count)
        return renderedLabel
            + String(repeating: "█", count: result.fillWidth)
            + String(repeating: "░", count: result.emptyWidth)
            + renderedSuffix
    }
}

public enum TemperatureBand: Equatable {
    case cool
    case warm
    case hot
    case warning

    public static func forCelsius(_ value: Double) -> TemperatureBand {
        guard value.isFinite else { return .warning }
        if value < 50 { return .cool }
        if value <= 70 { return .warm }
        return .hot
    }
}

public struct DashboardRenderer {
    private let ansi: Bool
    private let colorScheme: Int

    public init(ansi: Bool = true, colorScheme: Int = 2) {
        self.ansi = ansi
        self.colorScheme = min(6, max(0, colorScheme))
    }

    public func render(
        snapshot: DashboardSnapshot,
        histories: DashboardHistories,
        size: TerminalSize
    ) -> Data {
        let width = max(1, size.columns)
        if size.rows < 10 || size.columns < 40 {
            let warning = DisplayWidth.fit("Terminal too small — resize to at least 40×10", to: width)
            return Data((ansiPrefix + warning + "\n" + ansiSuffix).utf8)
        }

        func frameLines(compact: Bool) -> [String] {
            let chip = snapshot.topology.name.map { " — \($0)" } ?? ""
            let sections = [
                "silitop\(chip)",
                cpuSection(snapshot.cpu, topology: snapshot.topology, width: width, includeCoreRows: !compact),
                gpuSection(snapshot.gpu, topology: snapshot.topology, width: width),
                aneSection(snapshot.power, topology: snapshot.topology, width: width, now: snapshot.observedAt),
                fanSection(snapshot.fans, now: snapshot.observedAt),
                powerSection(snapshot.power, topology: snapshot.topology, histories: histories, now: snapshot.observedAt),
                networkSection(snapshot.network, histories: histories, now: snapshot.observedAt),
                diskSection(snapshot.disk, histories: histories, now: snapshot.observedAt),
                memorySection(snapshot.memory, now: snapshot.observedAt),
                temperatureSection(snapshot.temperatures, now: snapshot.observedAt, compact: compact),
                thermalSection(snapshot.thermalPressure, now: snapshot.observedAt),
                "q: quit  •  Ctrl-C: quit",
            ]
            return sections.flatMap {
                $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            }
        }

        let fullLines = frameLines(compact: false)
        let selected = fullLines.count <= size.rows ? fullLines : frameLines(compact: true)
        let visible = selected.prefix(max(1, size.rows))
        let body = visible.map { DisplayWidth.fit($0, to: width) }.joined(separator: "\n") + "\n"
        return Data((ansiPrefix + body + ansiSuffix).utf8)
    }

    private var ansiPrefix: String {
        guard ansi else { return "" }
        let codes = [37, 31, 32, 33, 34, 35, 36]
        return "\u{1B}[H\u{1B}[\(codes[colorScheme])m"
    }

    private var ansiSuffix: String {
        ansi ? "\u{1B}[J\u{1B}[0m" : ""
    }

    private var mainColorCode: String {
        guard ansi else { return "" }
        let codes = [37, 31, 32, 33, 34, 35, 36]
        return "\u{1B}[\(codes[colorScheme])m"
    }

    private func cpuSection(
        _ state: MetricState<CPUReading>,
        topology: Topology,
        width: Int,
        includeCoreRows: Bool
    ) -> String {
        switch state {
        case .unavailable:
            return "CPU: unavailable\n\(topology.fastLabel): unavailable\n\(topology.slowLabel): unavailable"
        case let .fresh(reading, _), let .stale(reading, _, _):
            var lines = ["CPU"]
            lines.append("\(topology.fastLabel)  \(reading.fastActivePercent)% @ \(formatFrequency(reading.fastFrequencyMHz))")
            if includeCoreRows {
                for (index, core) in reading.fastCores.enumerated() {
                    let suffix = String(format: " %3d%% %@", core.activePercent, formatFrequency(core.frequencyMHz))
                    lines.append(HorizontalBar.render(width: width, percent: core.activePercent, label: "\(topology.fastPrefix)\(index + 1) ", suffix: suffix))
                }
            }
            lines.append("\(topology.slowLabel)  \(reading.slowActivePercent)% @ \(formatFrequency(reading.slowFrequencyMHz))")
            if includeCoreRows {
                for (index, core) in reading.slowCores.enumerated() {
                    let suffix = String(format: " %3d%% %@", core.activePercent, formatFrequency(core.frequencyMHz))
                    lines.append(HorizontalBar.render(width: width, percent: core.activePercent, label: "\(topology.slowPrefix)\(index + 1) ", suffix: suffix))
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    private func gpuSection(_ state: MetricState<GPUReading>, topology: Topology, width: Int) -> String {
        switch state {
        case .unavailable:
            return "GPU: unavailable"
        case let .fresh(reading, _), let .stale(reading, _, _):
            let cores = topology.gpuCoreCount.map { " (\($0) cores)" } ?? ""
            let suffix = String(format: " %3d%% %@", reading.activePercent, formatFrequency(reading.frequencyMHz))
            return "GPU\(cores)\n" + HorizontalBar.render(width: width, percent: reading.activePercent, label: "GPU ", suffix: suffix)
        }
    }

    private func aneSection(
        _ state: MetricState<PowerReading>,
        topology: Topology,
        width: Int,
        now: Date
    ) -> String {
        switch state {
        case let .unavailable(reason):
            return "ANE: unavailable (\(reason))"
        case let .fresh(value, _):
            return aneText(value, topology: topology, width: width)
        case let .stale(value, observedAt, _):
            return aneText(value, topology: topology, width: width)
                + " — \(staleText(now: now, observedAt: observedAt))"
        }
    }

    private func aneText(_ value: PowerReading, topology: Topology, width: Int) -> String {
        let limit = max(0.001, topology.powerLimits.aneWatts)
        let rawPercent = value.aneWatts / limit * 100
        let boundedPercent = rawPercent.isFinite ? min(100, max(0, rawPercent)) : 0
        let percent = Int(boundedPercent.rounded())
        let suffix = String(format: " %3d%% %.1fW", percent, value.aneWatts)
        return "ANE\n" + HorizontalBar.render(width: width, percent: percent, label: "ANE ", suffix: suffix)
    }

    private func fanSection(_ state: MetricState<FanCollection>, now: Date) -> String {
        switch state {
        case let .unavailable(reason):
            return "Fans: unavailable (\(reason))"
        case let .fresh(collection, _):
            return fanText(collection)
        case let .stale(collection, observedAt, _):
            return fanText(collection) + " — \(staleText(now: now, observedAt: observedAt))"
        }
    }

    private func fanText(_ collection: FanCollection) -> String {
        switch collection {
        case .fanless:
            return "Fans: fanless"
        case let .fans(fans):
            let readings = fans.map { fan in
                String(format: "F%d %.0f/%.0f RPM", fan.index, fan.rpm, fan.maximumRPM)
            }
            return "Fans: " + readings.joined(separator: "  ")
        }
    }

    private func powerSection(
        _ state: MetricState<PowerReading>,
        topology: Topology,
        histories: DashboardHistories,
        now: Date
    ) -> String {
        switch state {
        case let .unavailable(reason):
            return "Power: unavailable (\(reason))"
        case let .fresh(value, _):
            return powerText(value, topology: topology, histories: histories)
        case let .stale(value, observedAt, _):
            return powerText(value, topology: topology, histories: histories) + " — \(staleText(now: now, observedAt: observedAt))"
        }
    }

    private func powerText(_ value: PowerReading, topology: Topology, histories: DashboardHistories) -> String {
        let trend = sparkline(histories.cpuPower, maximum: topology.powerLimits.cpuWatts)
        return String(
            format: "Power  CPU %.1fW (avg %.1f, peak %.1f) %@  GPU %.1fW (avg %.1f, peak %.1f)  ANE %.1fW  Package %.1fW",
            value.cpuWatts, value.cpuAverageWatts, value.cpuPeakWatts, trend,
            value.gpuWatts, value.gpuAverageWatts, value.gpuPeakWatts,
            value.aneWatts, value.packageWatts
        )
    }

    private func networkSection(_ state: MetricState<NetworkReading>, histories: DashboardHistories, now: Date) -> String {
        switch state {
        case let .unavailable(reason):
            return "Network: unavailable (\(reason))"
        case let .fresh(value, _):
            return networkText(value, histories: histories)
        case let .stale(value, observedAt, _):
            return networkText(value, histories: histories) + " — \(staleText(now: now, observedAt: observedAt))"
        }
    }

    private func networkText(_ value: NetworkReading, histories: DashboardHistories) -> String {
        "Network  ↓ \(formatRate(value.inBytesPerSecond)) \(sparkline(histories.networkIn))  ↑ \(formatRate(value.outBytesPerSecond)) \(sparkline(histories.networkOut))"
    }

    private func diskSection(_ state: MetricState<DiskReading>, histories: DashboardHistories, now: Date) -> String {
        switch state {
        case let .unavailable(reason):
            return "Disk I/O: unavailable (\(reason))"
        case let .fresh(value, _):
            return diskText(value, histories: histories)
        case let .stale(value, observedAt, _):
            return diskText(value, histories: histories) + " — \(staleText(now: now, observedAt: observedAt))"
        }
    }

    private func diskText(_ value: DiskReading, histories: DashboardHistories) -> String {
        "Disk I/O  read \(formatRate(value.readBytesPerSecond)) \(sparkline(histories.diskRead))  write \(formatRate(value.writeBytesPerSecond)) \(sparkline(histories.diskWrite))"
    }

    private func memorySection(_ state: MetricState<MemoryReading>, now: Date) -> String {
        switch state {
        case .unavailable:
            return "Memory: unavailable"
        case let .fresh(value, _):
            return memoryText(value)
        case let .stale(value, observedAt, _):
            return memoryText(value) + " — \(staleText(now: now, observedAt: observedAt))"
        }
    }

    private func memoryText(_ value: MemoryReading) -> String {
        let memory = String(
            format: "Memory  %.1f/%.1f GB (%d%%)  App %.1f  Wired %.1f  Compressed %.1f  Cached %.1f",
            value.usedGiB, value.totalGiB, value.percentUsed, value.appGiB, value.wiredGiB,
            value.compressedGiB, value.cachedGiB
        )
        guard let used = value.swapUsedGiB, let total = value.swapTotalGiB else {
            return memory + "  Swap unavailable"
        }
        return memory + String(format: "  Swap %.1f/%.1f GB", used, total)
    }

    private func temperatureSection(
        _ state: MetricState<[TemperatureReading]>,
        now: Date,
        compact: Bool
    ) -> String {
        switch state {
        case let .unavailable(reason):
            return "Temperatures: unavailable (\(reason))"
        case let .fresh(values, _):
            return temperatureText(values, compact: compact)
        case let .stale(values, observedAt, _):
            return temperatureText(values, compact: compact) + " — \(staleText(now: now, observedAt: observedAt))"
        }
    }

    private func temperatureText(_ values: [TemperatureReading], compact: Bool) -> String {
        let classified = TemperatureClassifier.classify(values)
        var lines = ["Temperatures"]
        var summary: [String] = []
        if !classified.cpuDie.isEmpty {
            let readings = classified.cpuDie.map(\.celsius)
            summary.append(String(
                format: "CPU Die %.0f°C (max %.0f°C)",
                readings.reduce(0, +) / Double(readings.count), readings.max() ?? 0
            ))
        }
        if !classified.gpuDie.isEmpty {
            let readings = classified.gpuDie.map(\.celsius)
            summary.append(String(format: "GPU Die %.0f°C", readings.reduce(0, +) / Double(readings.count)))
        }
        for name in ["SSD", "Battery"] {
            if let value = classified.other[name] {
                summary.append(String(format: "%@ %.0f°C", name, value))
            }
        }
        lines.append(summary.isEmpty ? "unavailable" : summary.joined(separator: "  "))
        if !compact, !classified.cpuDie.isEmpty {
            lines.append("CPU " + classified.cpuDie.map {
                coloredTemperatureToken(String(format: "z%d:%.0f", $0.zone, $0.celsius), value: $0.celsius)
            }.joined(separator: " "))
        }
        if !compact, !classified.gpuDie.isEmpty {
            lines.append("GPU " + classified.gpuDie.map {
                coloredTemperatureToken(String(format: "z%d:%.0f", $0.zone, $0.celsius), value: $0.celsius)
            }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    private func coloredTemperatureToken(_ text: String, value: Double) -> String {
        guard ansi else { return text }
        let code: Int
        switch TemperatureBand.forCelsius(value) {
        case .cool: code = 36
        case .warm, .warning: code = 33
        case .hot: code = 31
        }
        return "\u{1B}[\(code)m\(text)\(mainColorCode)"
    }

    private func thermalSection(_ state: MetricState<String>, now: Date) -> String {
        switch state {
        case let .unavailable(reason):
            return "Thermal Pressure: unavailable (\(reason))"
        case let .fresh(value, _):
            return "Thermal Pressure: \(value)"
        case let .stale(value, observedAt, _):
            return "Thermal Pressure: \(value) — \(staleText(now: now, observedAt: observedAt))"
        }
    }

    private func staleText(now: Date, observedAt: Date) -> String {
        "stale \(max(0, Int(now.timeIntervalSince(observedAt).rounded())))s"
    }

    private func formatFrequency(_ value: Int) -> String {
        value >= 1_000 ? String(format: "%.1fG", Double(value) / 1_000) : "\(value)M"
    }

    private func formatRate(_ value: Double) -> String {
        if value >= 1_073_741_824 { return String(format: "%.1f GiB/s", value / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.1f MiB/s", value / 1_048_576) }
        if value >= 1_024 { return String(format: "%.1f KiB/s", value / 1_024) }
        return String(format: "%.0f B/s", value)
    }

    private func sparkline(_ values: [Double], maximum fixedMaximum: Double? = nil) -> String {
        let validValues = values.map { $0.isFinite && $0 >= 0 ? $0 : 0 }
        let requestedMaximum = fixedMaximum.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard let maximum = requestedMaximum ?? validValues.max(), maximum > 0 else { return "" }
        let glyphs = Array("▁▂▃▄▅▆▇█")
        return String(validValues.suffix(12).map { value in
            let ratio = min(1, max(0, value / maximum))
            let index = Int((ratio * Double(glyphs.count - 1)).rounded(.towardZero))
            return glyphs[index]
        })
    }
}
