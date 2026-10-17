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
    // Display floor so a few watts of idle does not fill the row. Not a chip limit.
    private static let powerSparkFloorWatts = 20.0

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
        let columns = max(1, size.columns)
        let rows = max(1, size.rows)
        let screen = LegacyScreen(rows: rows, columns: columns)
        if size.rows < 10 || size.columns < 40 {
            screen.write(0, 0, "Terminal too small", foreground: 31)
            return screen.encode(through: 0, ansi: ansi)
        }
        let lastRow = paint(snapshot, histories: histories, on: screen)
        return screen.encode(through: lastRow, ansi: ansi)
    }

    func waiting(size: TerminalSize) -> Data {
        let columns = max(1, size.columns)
        let rows = max(1, size.rows)
        let screen = LegacyScreen(rows: rows, columns: columns)
        if size.rows < 10 || size.columns < 40 {
            screen.write(0, 0, "Terminal too small", foreground: 31)
            return screen.encode(through: 0, ansi: ansi)
        }
        let message = "Waiting for powermetrics data..."
        let note = "(requires sudo)"
        let y = rows / 2
        screen.write(y, max(0, (columns - message.count) / 2), message, foreground: 33)
        let noteRow = min(rows - 1, y + 1)
        screen.write(noteRow, max(0, (columns - note.count) / 2), note, foreground: 37)
        return screen.encode(through: noteRow, ansi: ansi)
    }

    // Fast cores on the left, slow cores on the right. Fans use only the
    // leftover rows under the fast box. A panel whose height does not fit
    // is skipped, same as the curses screen.
    private func paint(
        _ snapshot: DashboardSnapshot,
        histories: DashboardHistories,
        on screen: LegacyScreen
    ) -> Int {
        let columns = screen.columns
        let rows = screen.rows
        let half = columns / 2
        let leftW = half - 1
        let rightW = columns - half - 1
        let topology = snapshot.topology
        let header = "\(topology.name ?? "Apple Silicon") (\(countText(topology.fastCoreCount))\(topology.fastPrefix)+\(countText(topology.slowCoreCount))\(topology.slowPrefix)+\(countText(topology.gpuCoreCount))GPU)"
        screen.write(0, 0, centered(" silitop - \(header) ", columns), foreground: accentColor, bold: true, reverse: true)

        let classified = metricValue(snapshot.temperatures).map { TemperatureClassifier.classify($0) }
        let cpuDie = classified?.cpuDie ?? []
        let gpuDie = classified?.gpuDie ?? []
        let other = classified?.other ?? [:]
        let cpuDieMax = finiteMax(cpuDie.map(\.celsius))
        let gpuDieMax = finiteMax(gpuDie.map(\.celsius))
        let fans = fanList(snapshot.fans)
        let thermal = thermalText(snapshot.thermalPressure)
        var row = 1
        var last = 0

        if let cpu = metricValue(snapshot.cpu) {
            let fastBoxH = cpu.fastCores.count + 2
            let slowBoxH = cpu.slowCores.count + 2
            let cpuBoxH = max(fastBoxH, slowBoxH)
            if row + cpuBoxH < rows {
                var slowTitle = "\(topology.slowLabel): \(cpu.slowActivePercent)% @ \(cpu.slowFrequencyMHz) MHz"
                if let cpuDieMax {
                    slowTitle += "  \(degrees(cpuDieMax))°C"
                }
                let fastTitle = "\(topology.fastLabel): \(cpu.fastActivePercent)% @ \(cpu.fastFrequencyMHz) MHz"
                let blank = cpuBoxH - fastBoxH
                if !fans.isEmpty && blank >= 3 {
                    drawBox(screen, row, 0, fastBoxH, leftW, fastTitle)
                    drawBox(screen, row + fastBoxH, 0, blank, leftW, "Fans")
                    for (index, fan) in fans.enumerated() {
                        if index >= blank - 2 { break }
                        let fanY = row + fastBoxH + 1 + index
                        let label = fixedLabel("F", index + 1)
                        if fan.rpm == 0 {
                            screen.write(fanY, 2, label + "  off", foreground: 37, dim: true, clipRight: leftW - 1)
                        } else {
                            let pct = fan.maximumRPM > 0 ? safeInt(fan.rpm / fan.maximumRPM * 100) : 0
                            drawFanRow(screen, fanY, 2, leftW - 4, label, pct, fan.rpm)
                        }
                    }
                } else {
                    drawBox(screen, row, 0, cpuBoxH, leftW, fastTitle)
                }
                drawBox(screen, row, half, cpuBoxH, rightW, slowTitle)
                for (index, core) in cpu.fastCores.enumerated() {
                    drawCoreRow(screen, row + 1 + index, 2, leftW - 4, fixedLabel(topology.fastPrefix, index + 1), core.activePercent, core.frequencyMHz)
                }
                for (index, core) in cpu.slowCores.enumerated() {
                    drawCoreRow(screen, row + 1 + index, half + 2, rightW - 4, fixedLabel(topology.slowPrefix, index + 1), core.activePercent, core.frequencyMHz)
                }
                last = max(last, row + cpuBoxH - 1)
                row += cpuBoxH
            }
        } else if row + 4 < rows {
            drawUnavailable(screen, row, 0, 4, columns, "CPU")
            last = max(last, row + 3)
            row += 4
        }

        if row + 3 < rows {
            if let gpu = metricValue(snapshot.gpu) {
                var gpuTitle = "GPU: \(gpu.activePercent)% @ \(gpu.frequencyMHz) MHz"
                if let gpuDieMax {
                    gpuTitle += "  \(degrees(gpuDieMax))°C"
                }
                drawBox(screen, row, 0, 3, columns, gpuTitle)
                drawHBar(screen, row + 1, 2, columns - 4, gpu.activePercent, "", accentColor)
            } else {
                drawUnavailable(screen, row, 0, 3, columns, "GPU")
            }
            last = max(last, row + 2)
            row += 3
        }

        if row + 3 < rows {
            if let power = metricValue(snapshot.power) {
                let pct = anePercent(power.aneWatts, limit: topology.powerLimits.aneWatts)
                drawBox(screen, row, 0, 3, columns, "ANE: \(pct)% @ \(watts(power.aneWatts))W")
                drawHBar(screen, row + 1, 2, columns - 4, pct, "", 36)
            } else {
                drawUnavailable(screen, row, 0, 3, columns, "ANE")
            }
            last = max(last, row + 2)
            row += 3
        }

        if row + 4 < rows {
            if let net = metricValue(snapshot.network) {
                let title = "Net: ↓\(formatRate(net.inBytesPerSecond)) ↑\(formatRate(net.outBytesPerSecond))"
                drawBox(screen, row, 0, 4, leftW, title)
                let sparkAvail = leftW - 4
                if sparkAvail > 10 && histories.networkIn.count > 1 {
                    let hw = sparkAvail / 2
                    screen.write(row + 1, 2, "↓", foreground: 36)
                    drawSpark(screen, row + 1, 3, hw - 1, histories.networkIn, 1, 36)
                    let mid = 2 + hw + 1
                    screen.write(row + 1, mid, "↑", foreground: 31)
                    drawSpark(screen, row + 1, mid + 1, hw - 1, histories.networkOut, 1, 31)
                }
            } else {
                drawUnavailable(screen, row, 0, 4, leftW, "Net")
            }
            if let disk = metricValue(snapshot.disk) {
                let title = "Disk: R \(formatRate(disk.readBytesPerSecond)) W \(formatRate(disk.writeBytesPerSecond))"
                drawBox(screen, row, half, 4, rightW, title)
                let sparkAvail = rightW - 4
                if sparkAvail > 10 && histories.diskRead.count > 1 {
                    let hw = sparkAvail / 2
                    screen.write(row + 1, half + 2, "R", foreground: 36)
                    drawSpark(screen, row + 1, half + 3, hw - 1, histories.diskRead, 1, 36)
                    let mid = half + 2 + hw + 1
                    screen.write(row + 1, mid, "W", foreground: 31)
                    drawSpark(screen, row + 1, mid + 1, hw - 1, histories.diskWrite, 1, 31)
                }
            } else {
                drawUnavailable(screen, row, half, 4, rightW, "Disk")
            }
            last = max(last, row + 3)
            row += 4
        }

        if row + 9 < rows {
            if let memory = metricValue(snapshot.memory) {
                drawBox(screen, row, 0, 9, leftW, "Memory")
                let ram = "RAM: \(oneDecimal(memory.usedGiB))/\(oneDecimal(memory.totalGiB)) GB (\(memory.percentUsed)%)"
                screen.write(row + 1, 2, ram, foreground: 37, clipRight: leftW - 1)
                drawHBar(screen, row + 2, 2, leftW - 4, memory.percentUsed, "", 32)
                if let total = memory.swapTotalGiB, let used = memory.swapUsedGiB, total > 0.05 {
                    screen.write(row + 3, 2, "Swap: \(oneDecimal(used))/\(oneDecimal(total)) GB", foreground: 37, clipRight: leftW - 1)
                } else {
                    screen.write(row + 3, 2, "Swap: inactive", foreground: 37, dim: true, clipRight: leftW - 1)
                }
                let app = oneDecimal(memory.appGiB)
                let wired = oneDecimal(memory.wiredGiB)
                let compressed = oneDecimal(memory.compressedGiB)
                let cached = oneDecimal(memory.cachedGiB)
                let full = "App \(app)G  Wired \(wired)G  Comp \(compressed)G  Cache \(cached)G"
                let short = "App \(app)G W \(wired)G C \(compressed)G"
                let avail = leftW - 4
                let breakdown = avail >= full.count ? full : (avail >= short.count ? short : "App \(app)G  C \(compressed)G")
                if avail > 0 {
                    screen.write(row + 4, 2, String(breakdown.prefix(avail)), foreground: 37, dim: true, clipRight: 2 + avail)
                }
            } else {
                drawUnavailable(screen, row, 0, 9, leftW, "Memory")
            }

            if let power = metricValue(snapshot.power) {
                drawBox(screen, row, half, 9, rightW, "Power")
                let clip = half + rightW - 1
                let origin = half + 2
                screen.write(row + 1, origin, "CPU: \(watts(power.cpuWatts))W  GPU: \(watts(power.gpuWatts))W  ANE: \(watts(power.aneWatts))W  Total: \(watts(power.packageWatts))W", foreground: 37, clipRight: clip)
                screen.write(row + 2, origin, "CPU avg: \(watts(power.cpuAverageWatts))W pk: \(watts(power.cpuPeakWatts))W  GPU avg: \(watts(power.gpuAverageWatts))W pk: \(watts(power.gpuPeakWatts))W", foreground: 37, dim: true, clipRight: clip)
                let throttlePrefix = "Package peak: \(watts(power.packagePeakWatts))W  Throttle: "
                screen.write(row + 3, origin, throttlePrefix, foreground: 37, clipRight: clip)
                let throttle = thermal == "Nominal" ? "no" : "YES (\(thermal))"
                screen.write(row + 3, origin + throttlePrefix.count, throttle, foreground: thermal == "Nominal" ? 32 : 31, clipRight: clip)
                let sparkW = rightW - 8
                if sparkW > 10 && histories.cpuPower.count > 1 {
                    screen.write(row + 4, origin, "CPU ", foreground: 37)
                    drawSpark(screen, row + 4, half + 6, sparkW, histories.cpuPower, Self.powerSparkFloorWatts, accentColor)
                    screen.write(row + 6, origin, "GPU ", foreground: 37)
                    drawSpark(screen, row + 6, half + 6, sparkW, histories.gpuPower, Self.powerSparkFloorWatts, 33)
                }
            } else {
                drawUnavailable(screen, row, half, 9, rightW, "Power")
            }
            last = max(last, row + 8)
            row += 9
        }

        let hasTemps = !cpuDie.isEmpty || !gpuDie.isEmpty || !other.isEmpty
        let tempBoxH = hasTemps ? 6 : 3
        if row + tempBoxH < rows {
            if hasTemps {
                drawBox(screen, row, 0, tempBoxH, columns, "Temperatures")
                var cy = row + 1
                var parts: [String] = []
                let cpuVals = cpuDie.map(\.celsius).filter(\.isFinite)
                if !cpuVals.isEmpty {
                    let avg = cpuVals.reduce(0, +) / Double(cpuVals.count)
                    parts.append("CPU Die: \(degrees(avg))°C (max \(degrees(cpuVals.max() ?? 0))°C)")
                }
                let gpuVals = gpuDie.map(\.celsius).filter(\.isFinite)
                if !gpuVals.isEmpty {
                    let avg = gpuVals.reduce(0, +) / Double(gpuVals.count)
                    parts.append("GPU Die: \(degrees(avg))°C")
                }
                for label in ["SSD", "Battery"] {
                    if let value = other[label], value.isFinite {
                        parts.append("\(label): \(degrees(value))°C")
                    }
                }
                screen.write(cy, 2, parts.joined(separator: "  "), foreground: 37, clipRight: columns - 1)
                cy += 1
                if !cpuDie.isEmpty {
                    drawZones(screen, cy, columns, "CPU ", cpuDie)
                    cy += 1
                }
                if !gpuDie.isEmpty {
                    drawZones(screen, cy, columns, "GPU ", gpuDie)
                    cy += 1
                }
                let pressureRow = min(cy, row + tempBoxH - 2)
                screen.write(pressureRow, 2, "Thermal Pressure: ", foreground: 37)
                screen.write(pressureRow, 2 + "Thermal Pressure: ".count, thermal, foreground: thermal == "Nominal" ? 32 : 31, clipRight: columns - 1)
                last = max(last, row + tempBoxH - 1)
                row += tempBoxH
            } else {
                screen.write(row, 0, String(repeating: "─", count: columns), foreground: accentColor)
                row += 1
                screen.write(row, 2, "Thermal Pressure: ", foreground: 37)
                screen.write(row, 2 + "Thermal Pressure: ".count, thermal, foreground: thermal == "Nominal" ? 32 : 31, clipRight: columns - 1)
                last = max(last, row)
                row += 1
            }
        }

        if row < rows {
            let y = min(row, rows - 1)
            screen.write(y, 0, centered(" q: quit | silitop ", columns), foreground: 37, dim: true)
            last = max(last, y)
        }
        return last
    }

    private var accentColor: Int {
        [37, 31, 32, 33, 34, 35, 36][colorScheme]
    }

    private func drawBox(_ screen: LegacyScreen, _ y: Int, _ x: Int, _ h: Int, _ w: Int, _ title: String) {
        guard h >= 2, w >= 4 else { return }
        let horizontal = String(repeating: "─", count: w - 2)
        screen.write(y, x, "┌" + horizontal + "┐", foreground: accentColor)
        if !title.isEmpty {
            let titled = " \(title) "
            if x + 2 + titled.count < x + w - 1 {
                screen.write(y, x + 2, titled, foreground: accentColor, bold: true)
            }
        }
        if h > 2 {
            for line in (y + 1)..<(y + h - 1) {
                screen.write(line, x, "│", foreground: accentColor)
                screen.write(line, x + w - 1, "│", foreground: accentColor)
            }
        }
        screen.write(y + h - 1, x, "└" + horizontal + "┘", foreground: accentColor)
    }

    private func drawUnavailable(_ screen: LegacyScreen, _ y: Int, _ x: Int, _ h: Int, _ w: Int, _ title: String) {
        drawBox(screen, y, x, h, w, title)
        guard h >= 2, w >= 6 else { return }
        var message = "data unavailable"
        if message.count > w - 4 { message = "unavailable" }
        let mid = y + max(1, h / 2)
        let column = x + max(1, (w - message.count) / 2)
        screen.write(mid, column, message, foreground: 33, dim: true, clipRight: x + w - 1)
    }

    private func drawCoreRow(
        _ screen: LegacyScreen,
        _ y: Int,
        _ x: Int,
        _ width: Int,
        _ label: String,
        _ percent: Int,
        _ frequencyMHz: Int
    ) {
        guard width >= 20 else { return }
        let pct = min(100, max(0, percent))
        let pctText = String(format: "%3d%%", pct)
        let frequency = padLeft(frequencyMHz >= 1_000 ? String(format: "%.1fG", Double(frequencyMHz) / 1_000) : "\(frequencyMHz)M", 4)
        let suffix = " \(pctText) \(frequency)"
        let labelText = label + " "
        let layout = barGeometry(width: width, percent: pct, label: labelText, suffix: suffix)
        let clip = x + width
        screen.write(y, x, labelText, foreground: 37, bold: true, clipRight: clip)
        screen.write(y, x + layout.labelWidth, String(repeating: "█", count: layout.fill), foreground: accentColor, bold: true, clipRight: clip)
        screen.write(y, x + layout.labelWidth + layout.fill, String(repeating: "░", count: layout.empty), foreground: 37, dim: true, clipRight: clip)
        screen.write(y, x + layout.suffixStart, " " + pctText, foreground: 37, clipRight: clip)
        screen.write(y, x + layout.suffixStart + 1 + pctText.count, " " + frequency, foreground: 36, clipRight: clip)
    }

    private func drawFanRow(
        _ screen: LegacyScreen,
        _ y: Int,
        _ x: Int,
        _ width: Int,
        _ label: String,
        _ percent: Int,
        _ rpm: Double
    ) {
        guard width >= 20 else { return }
        let pct = min(100, max(0, percent))
        let pctText = String(format: "%3d%%", pct)
        let rpmText = padLeft("\(safeInt(rpm))r", 5)
        let suffix = " \(pctText) \(rpmText)"
        let labelText = label + " "
        let layout = barGeometry(width: width, percent: pct, label: labelText, suffix: suffix)
        let clip = x + width
        screen.write(y, x, labelText, foreground: 37, bold: true, clipRight: clip)
        screen.write(y, x + layout.labelWidth, String(repeating: "█", count: layout.fill), foreground: accentColor, bold: true, clipRight: clip)
        screen.write(y, x + layout.labelWidth + layout.fill, String(repeating: "░", count: layout.empty), foreground: 37, dim: true, clipRight: clip)
        screen.write(y, x + layout.suffixStart, " " + pctText, foreground: 37, clipRight: clip)
        screen.write(y, x + layout.suffixStart + 1 + pctText.count, " " + rpmText, foreground: 36, clipRight: clip)
    }

    private func drawHBar(
        _ screen: LegacyScreen,
        _ y: Int,
        _ x: Int,
        _ width: Int,
        _ percent: Int,
        _ label: String,
        _ foreground: Int
    ) {
        guard width >= 10 else { return }
        let pct = min(100, max(0, percent))
        let pctText = String(format: " %3d%%", pct)
        let labelText = label.isEmpty ? "" : label + " "
        let layout = barGeometry(width: width, percent: pct, label: labelText, suffix: pctText)
        let clip = x + width
        if !labelText.isEmpty {
            screen.write(y, x, labelText, foreground: 37, clipRight: clip)
        }
        screen.write(y, x + layout.labelWidth, String(repeating: "█", count: layout.fill), foreground: foreground, bold: true, clipRight: clip)
        screen.write(y, x + layout.labelWidth + layout.fill, String(repeating: "░", count: layout.empty), foreground: 37, dim: true, clipRight: clip)
        screen.write(y, x + layout.suffixStart, pctText, foreground: 37, clipRight: clip)
    }

    private func drawSpark(
        _ screen: LegacyScreen,
        _ y: Int,
        _ x: Int,
        _ width: Int,
        _ values: [Double],
        _ floor: Double,
        _ foreground: Int
    ) {
        guard width >= 3, !values.isEmpty, y + 1 < screen.rows else { return }
        let glyphs = Array("▁▂▃▄▅▆▇█")
        let drawn = values.suffix(width)
        let visibleMax = drawn.lazy.filter(\.isFinite).max() ?? 0
        let floorValue = floor.isFinite ? floor : 0
        let scale = max(visibleMax, floorValue, 0.01)
        for (offset, raw) in drawn.enumerated() {
            let sample = raw.isFinite ? raw : 0
            let ratio = min(max(sample / scale, 0), 1)
            let index = min(15, Int(ratio * 15))
            let top: Character
            let bottom: Character
            if index < 8 {
                top = " "
                bottom = glyphs[index]
            } else {
                top = glyphs[index - 8]
                bottom = glyphs[7]
            }
            screen.write(y, x + offset, String(top), foreground: foreground)
            screen.write(y + 1, x + offset, String(bottom), foreground: foreground)
        }
    }

    private func drawZones(
        _ screen: LegacyScreen,
        _ y: Int,
        _ columns: Int,
        _ prefix: String,
        _ zones: [DieTemperature]
    ) {
        var cx = 2
        screen.write(y, cx, prefix, foreground: 37, dim: true)
        cx += prefix.count
        for zone in zones where zone.celsius.isFinite {
            let entry = "z\(zone.zone):\(degrees(zone.celsius))"
            if cx + entry.count + 1 > columns - 2 { break }
            screen.write(y, cx, entry, foreground: temperatureColor(zone.celsius))
            cx += entry.count + 1
        }
    }

    private func barGeometry(width: Int, percent: Int, label: String, suffix: String) -> (labelWidth: Int, fill: Int, empty: Int, suffixStart: Int) {
        let total = max(width, 0)
        let pct = min(100, max(0, percent))
        let labelWidth = min(label.count, total)
        let suffixStart = min(max(labelWidth, total - suffix.count), total)
        let barWidth = max(suffixStart - labelWidth, 0)
        let fill = min(barWidth, Int(Double(pct) / 100 * Double(barWidth)))
        return (labelWidth, fill, barWidth - fill, suffixStart)
    }

    private func metricValue<T>(_ state: MetricState<T>) -> T? {
        switch state {
        case .unavailable:
            return nil
        case let .fresh(value, _), let .stale(value, _, _):
            return value
        }
    }

    private func fanList(_ state: MetricState<FanCollection>) -> [FanReading] {
        guard let collection = metricValue(state), case let .fans(fans) = collection else { return [] }
        return fans
    }

    private func thermalText(_ state: MetricState<String>) -> String {
        switch state {
        case .unavailable:
            return "Unknown"
        case let .fresh(value, _), let .stale(value, _, _):
            return value
        }
    }

    private func temperatureColor(_ value: Double) -> Int {
        guard value.isFinite, value >= 0 else { return 33 }
        if value < 50 { return 36 }
        if value <= 70 { return 33 }
        return 31
    }

    private func anePercent(_ wattsValue: Double, limit: Double) -> Int {
        guard wattsValue.isFinite, limit.isFinite, limit > 0 else { return 0 }
        return min(100, max(0, safeInt(wattsValue / limit * 100)))
    }

    private func safeInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }

    private func watts(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f", value) : "nan"
    }

    private func oneDecimal(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f", value) : "nan"
    }

    private func degrees(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private func finiteMax(_ values: [Double]) -> Double? {
        values.filter(\.isFinite).max()
    }

    private func countText(_ value: Int?) -> String {
        value.map(String.init) ?? "?"
    }

    private func fixedLabel(_ prefix: String, _ number: Int) -> String {
        let digits = String(number)
        guard digits.count < 2 else { return prefix + digits }
        return prefix + digits + String(repeating: " ", count: 2 - digits.count)
    }

    private func padLeft(_ text: String, _ width: Int) -> String {
        guard text.count < width else { return text }
        return String(repeating: " ", count: width - text.count) + text
    }

    private func centered(_ text: String, _ width: Int) -> String {
        guard text.count < width else { return text }
        let pad = width - text.count
        let left = pad / 2
        return String(repeating: " ", count: left) + text + String(repeating: " ", count: pad - left)
    }

    private func formatRate(_ value: Double) -> String {
        guard value.isFinite else { return "0 B/s" }
        if value >= 1_073_741_824 { return String(format: "%.1f GB/s", value / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.1f MB/s", value / 1_048_576) }
        if value >= 1_024 { return String(format: "%.0f KB/s", value / 1_024) }
        return String(format: "%.0f B/s", value)
    }
}

private struct LegacyGlyph: Equatable {
    var character: Character = " "
    var foreground: Int?
    var bold = false
    var dim = false
    var reverse = false

    var style: (Int?, Bool, Bool, Bool) {
        (foreground, bold, dim, reverse)
    }
}

private final class LegacyScreen {
    let rows: Int
    let columns: Int
    private var cells: [LegacyGlyph]

    init(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
        cells = Array(repeating: LegacyGlyph(), count: rows * columns)
    }

    func write(
        _ y: Int,
        _ x: Int,
        _ text: String,
        foreground: Int? = nil,
        bold: Bool = false,
        dim: Bool = false,
        reverse: Bool = false,
        clipRight: Int? = nil
    ) {
        guard rows > 0, columns > 0, y >= 0, y < rows, !text.isEmpty else { return }
        var column = x
        var characters = Array(text)
        if column < 0 {
            let skip = min(characters.count, -column)
            characters.removeFirst(skip)
            column = 0
        }
        let limit = min(columns, clipRight ?? columns)
        for character in characters {
            if column >= limit { break }
            cells[y * columns + column] = LegacyGlyph(
                character: character,
                foreground: foreground,
                bold: bold,
                dim: dim,
                reverse: reverse
            )
            column += 1
        }
    }

    func encode(through lastRow: Int, ansi: Bool) -> Data {
        guard rows > 0, columns > 0 else {
            return Data((ansi ? "\u{1B}[H\u{1B}[J\u{1B}[0m" : "").utf8)
        }
        let end = min(rows - 1, max(0, lastRow))
        var text = ansi ? "\u{1B}[H" : ""
        var previous: (Int?, Bool, Bool, Bool)?
        for y in 0...end {
            if y > 0 { text.append("\n") }
            for x in 0..<columns {
                let glyph = cells[y * columns + x]
                let style = glyph.style
                let styleChanged: Bool
                if let previous {
                    styleChanged = previous != style
                } else {
                    styleChanged = true
                }
                if ansi, styleChanged {
                    text.append(contentsOf: sgr(glyph))
                    previous = style
                }
                text.append(glyph.character)
            }
        }
        text.append("\n")
        if ansi { text.append(contentsOf: "\u{1B}[J\u{1B}[0m") }
        return Data(text.utf8)
    }

    private func sgr(_ glyph: LegacyGlyph) -> String {
        var codes = ["0"]
        if glyph.bold { codes.append("1") }
        if glyph.dim { codes.append("2") }
        if glyph.reverse { codes.append("7") }
        if let foreground = glyph.foreground { codes.append(String(foreground)) }
        return "\u{1B}[" + codes.joined(separator: ";") + "m"
    }
}
