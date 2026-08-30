import Darwin
import Foundation

public enum SystemSysctl {
    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return nil }
            return String(cString: base).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }
}

public final class HostMemoryCollector {
    private let hostPort: host_t

    public init() {
        hostPort = mach_host_self()
    }

    deinit {
        if hostPort != MACH_PORT_NULL {
            mach_port_deallocate(mach_task_self_, hostPort)
        }
    }

    public func read() -> MemoryReading? {
        guard let totalBytes = SystemSysctl.uint64("hw.memsize") else { return nil }
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                host_statistics64(hostPort, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let snapshot = VMStatisticsSnapshot(
            anonymousPages: UInt64(statistics.internal_page_count),
            wiredPages: UInt64(statistics.wire_count),
            compressorPages: UInt64(statistics.compressor_page_count),
            fileBackedPages: UInt64(statistics.external_page_count),
            pageSize: UInt64(vm_kernel_page_size)
        )
        return MemoryCalculator.calculateIfValid(
            statistics: snapshot,
            totalBytes: totalBytes,
            swap: readSwap()
        )
    }

    private func readSwap() -> SwapReading? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return nil
        }
        return SwapReading(totalBytes: usage.xsu_total, usedBytes: usage.xsu_used)
    }
}
