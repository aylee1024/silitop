import Foundation

public struct NULRecordFramer {
    private var buffer = Data()
    private let maxRecordBytes: Int
    private var droppingOversizedRecord = false
    public private(set) var droppedRecordCount = 0

    public init(maxRecordBytes: Int = 1_048_576) {
        self.maxRecordBytes = max(0, maxRecordBytes)
    }

    public mutating func push(_ chunk: Data) -> [Data] {
        var records: [Data] = []
        var start = chunk.startIndex

        while let separator = chunk[start...].firstIndex(of: 0) {
            let segment = chunk[start..<separator]
            if droppingOversizedRecord {
                droppingOversizedRecord = false
            } else if buffer.count + segment.count <= maxRecordBytes {
                buffer.append(contentsOf: segment)
                if !buffer.isEmpty { records.append(buffer) }
                buffer.removeAll(keepingCapacity: true)
            } else {
                droppedRecordCount += 1
                buffer.removeAll(keepingCapacity: true)
            }
            start = chunk.index(after: separator)
        }

        let remainder = chunk[start...]
        guard !droppingOversizedRecord else { return records }
        if buffer.count + remainder.count > maxRecordBytes {
            droppedRecordCount += 1
            droppingOversizedRecord = true
            buffer.removeAll(keepingCapacity: true)
        } else {
            buffer.append(contentsOf: remainder)
        }
        return records
    }
}
