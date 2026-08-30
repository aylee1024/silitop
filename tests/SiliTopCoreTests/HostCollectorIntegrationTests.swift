import XCTest
@testable import SiliTopCore

final class HostCollectorIntegrationTests: XCTestCase {
    func testSysctlReadsPhysicalMemoryWithoutAChildProcess() {
        let bytes = SystemSysctl.uint64("hw.memsize")

        XCTAssertNotNil(bytes)
        XCTAssertGreaterThan(bytes ?? 0, 1_073_741_824)
    }

    func testHostMemoryCollectorReturnsPlausibleNativeCounters() {
        let result = HostMemoryCollector().read()

        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result?.totalGiB ?? 0, 1)
        XCTAssertGreaterThanOrEqual(result?.percentUsed ?? -1, 0)
        XCTAssertLessThanOrEqual(result?.percentUsed ?? 101, 100)
    }
}
