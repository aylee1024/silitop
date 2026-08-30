import Foundation

public struct VMStatisticsSnapshot: Equatable, Sendable {
    public let anonymousPages: UInt64
    public let wiredPages: UInt64
    public let compressorPages: UInt64
    public let fileBackedPages: UInt64
    public let pageSize: UInt64

    public init(
        anonymousPages: UInt64,
        wiredPages: UInt64,
        compressorPages: UInt64,
        fileBackedPages: UInt64,
        pageSize: UInt64
    ) {
        self.anonymousPages = anonymousPages
        self.wiredPages = wiredPages
        self.compressorPages = compressorPages
        self.fileBackedPages = fileBackedPages
        self.pageSize = pageSize
    }
}

public struct SwapReading: Equatable, Sendable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64

    public init(totalBytes: UInt64, usedBytes: UInt64) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
    }
}

public struct MemoryReading: Equatable, Sendable {
    public let totalGiB: Double
    public let usedGiB: Double
    public let freeGiB: Double
    public let percentUsed: Int
    public let wiredGiB: Double
    public let compressedGiB: Double
    public let appGiB: Double
    public let cachedGiB: Double
    public let swapTotalGiB: Double?
    public let swapUsedGiB: Double?
}

public enum MemoryCalculator {
    public static func calculate(
        statistics: VMStatisticsSnapshot,
        totalBytes: UInt64,
        swap: SwapReading?
    ) -> MemoryReading {
        precondition(statistics.pageSize > 0)
        return calculateIfValid(statistics: statistics, totalBytes: totalBytes, swap: swap)!
    }

    public static func calculateIfValid(
        statistics: VMStatisticsSnapshot,
        totalBytes: UInt64,
        swap: SwapReading?
    ) -> MemoryReading? {
        guard statistics.pageSize > 0, totalBytes > 0 else { return nil }
        let totalPages = totalBytes / statistics.pageSize
        guard totalPages > 0 else { return nil }

        let summedPages = statistics.anonymousPages
            .addingReportingOverflow(statistics.wiredPages)
        guard !summedPages.overflow else { return nil }
        let allUsedPages = summedPages.partialValue
            .addingReportingOverflow(statistics.compressorPages)
        guard !allUsedPages.overflow else { return nil }
        let usedPages = min(allUsedPages.partialValue, totalPages)
        let freePages = totalPages - usedPages

        return MemoryReading(
            totalGiB: gibibytes(bytes: totalBytes),
            usedGiB: gibibytes(pages: usedPages, pageSize: statistics.pageSize),
            freeGiB: gibibytes(pages: freePages, pageSize: statistics.pageSize),
            percentUsed: min(100, Int(Double(usedPages) / Double(totalPages) * 100)),
            wiredGiB: gibibytes(pages: statistics.wiredPages, pageSize: statistics.pageSize),
            compressedGiB: gibibytes(pages: statistics.compressorPages, pageSize: statistics.pageSize),
            appGiB: gibibytes(pages: statistics.anonymousPages, pageSize: statistics.pageSize),
            cachedGiB: gibibytes(pages: statistics.fileBackedPages, pageSize: statistics.pageSize),
            swapTotalGiB: swap.map { gibibytes(bytes: $0.totalBytes) },
            swapUsedGiB: swap.map { gibibytes(bytes: $0.usedBytes) }
        )
    }
}

private func gibibytes(pages: UInt64, pageSize: UInt64) -> Double {
    let bytes = Double(pages) * Double(pageSize)
    return roundedTenth(bytes / 1_073_741_824)
}

private func gibibytes(bytes: UInt64) -> Double {
    roundedTenth(Double(bytes) / 1_073_741_824)
}

private func roundedTenth(_ value: Double) -> Double {
    (value * 10).rounded() / 10
}
