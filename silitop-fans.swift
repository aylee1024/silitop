import Foundation
import IOKit

// ── SMC data structures ─────────────────────────────────────────────
// Must match the kernel's SMCParamStruct layout exactly.

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers: SMCVersion = SMCVersion()
    var pLimitData: SMCPLimitData = SMCPLimitData()
    var keyInfo: SMCKeyInfoData = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// ── Helpers ─────────────────────────────────────────────────────────

func fourCharCode(_ s: String) -> UInt32 {
    var result: UInt32 = 0
    for byte in s.utf8.prefix(4) {
        result = (result << 8) | UInt32(byte)
    }
    return result
}

func openSMC() -> io_connect_t? {
    let service = IOServiceGetMatchingService(
        0, IOServiceMatching("AppleSMC"))
    guard service != 0 else { return nil }
    var conn: io_connect_t = 0
    let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
    IOObjectRelease(service)
    return kr == kIOReturnSuccess ? conn : nil
}

func readSMCKey(_ conn: io_connect_t, key: UInt32) -> SMCParamStruct? {
    let structSize = MemoryLayout<SMCParamStruct>.stride

    // Step 1: get key info (data8 = 9)
    var input = SMCParamStruct()
    input.key = key
    input.data8 = 9
    var output = SMCParamStruct()
    var outputSize = structSize
    var kr = IOConnectCallStructMethod(
        conn, UInt32(2),
        &input, structSize,
        &output, &outputSize)
    guard kr == kIOReturnSuccess else { return nil }

    // Step 2: read key value (data8 = 5)
    input.keyInfo = output.keyInfo
    input.data8 = 5
    output = SMCParamStruct()
    outputSize = structSize
    kr = IOConnectCallStructMethod(
        conn, UInt32(2),
        &input, structSize,
        &output, &outputSize)
    guard kr == kIOReturnSuccess else { return nil }

    return output
}

func bytesToFloat(_ b: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> Float {
    var raw = [b.0, b.1, b.2, b.3]
    var value: Float = 0
    memcpy(&value, &raw, 4)
    return value
}

// ── Main ────────────────────────────────────────────────────────────

guard let conn = openSMC() else { exit(0) }
defer { IOServiceClose(conn) }

// Read number of fans
guard let fnumOut = readSMCKey(conn, key: fourCharCode("FNum")) else { exit(0) }
let numFans = Int(fnumOut.bytes.0)
if numFans == 0 { exit(0) }

for i in 0..<numFans {
    let acKey = fourCharCode("F\(i)Ac")
    let mxKey = fourCharCode("F\(i)Mx")

    var rpm: Float = 0
    var maxRpm: Float = 0

    if let out = readSMCKey(conn, key: acKey) {
        rpm = bytesToFloat(out.bytes)
    }
    if let out = readSMCKey(conn, key: mxKey) {
        maxRpm = bytesToFloat(out.bytes)
    }

    // Sanity check: skip implausible values
    if rpm < 0 { rpm = 0 }
    if maxRpm <= 0 { maxRpm = 6500 }  // fallback max RPM

    print("FAN\(i)|\(String(format: "%.0f", rpm))|\(String(format: "%.0f", maxRpm))")
}
