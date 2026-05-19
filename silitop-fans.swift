import Foundation
import IOKit

// silitop-fans v1
//
// Protocol (stdout, line-delimited UTF-8):
//   silitop-fans v1
//   STATUS|ok | STATUS|fanless | STATUS|smc_unavailable
//   FAN<i>|<rpm>|<max_rpm>     (only when STATUS|ok)
//
// Exit codes:
//   0 = STATUS|ok (one or more fans) OR STATUS|fanless (no fans installed)
//   2 = STATUS|smc_unavailable (AppleSMC could not be opened)
//   3 = STATUS|fnum_read_failed (AppleSMC open but FNum unreadable)
//
// The Python side reads the header to detect version mismatch (returns None
// for broken-helper case) and the STATUS line to distinguish "no fans
// installed" from "broken SMC". The prior implementation returned exit 0
// with empty stdout for all three cases, making them indistinguishable and
// permanently disabling fan reads after one transient SMC contention.

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

func fourCharString(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >>  8) & 0xFF),
        UInt8( value        & 0xFF),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? ""
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
    let keyInfo = output.keyInfo  // preserve dataType across step 2

    // Step 2: read key value (data8 = 5)
    input.keyInfo = keyInfo
    input.data8 = 5
    output = SMCParamStruct()
    outputSize = structSize
    kr = IOConnectCallStructMethod(
        conn, UInt32(2),
        &input, structSize,
        &output, &outputSize)
    guard kr == kIOReturnSuccess else { return nil }
    // Step 2's output frame has a fresh (zeroed) keyInfo; restore the
    // dataType from step 1 so decodeSMC's switch can dispatch correctly.
    output.keyInfo = keyInfo
    return output
}

// Decode SMC numeric payloads. The previous implementation treated every
// payload as a 32-bit float, which silently mis-decoded `fpe2` keys
// (16-bit unsigned, two fractional bits) into ~0 RPM. Now we switch on
// the dataType returned in step 1 of readSMCKey.
func decodeSMC(_ frame: SMCParamStruct) -> Double? {
    let kind = fourCharString(frame.keyInfo.dataType)
    let bytes = frame.bytes
    switch kind {
    case "fpe2":
        let raw = (UInt16(bytes.0) << 8) | UInt16(bytes.1)
        return Double(raw) / 4.0
    case "flt ":
        var f: Float = 0
        var buf = [bytes.0, bytes.1, bytes.2, bytes.3]
        memcpy(&f, &buf, 4)
        return Double(f)
    case "ui16":
        let raw = (UInt16(bytes.0) << 8) | UInt16(bytes.1)
        return Double(raw)
    case "ui32":
        let raw = (UInt32(bytes.0) << 24)
                | (UInt32(bytes.1) << 16)
                | (UInt32(bytes.2) <<  8)
                |  UInt32(bytes.3)
        return Double(raw)
    case "ui8 ":
        return Double(bytes.0)
    default:
        return nil
    }
}

func emit(_ line: String) {
    print(line)
}

// ── Main ────────────────────────────────────────────────────────────

emit("silitop-fans v1")

guard let conn = openSMC() else {
    emit("STATUS|smc_unavailable")
    FileHandle.standardError.write("openSMC failed\n".data(using: .utf8)!)
    exit(2)
}
defer { IOServiceClose(conn) }

guard let fnumOut = readSMCKey(conn, key: fourCharCode("FNum")) else {
    emit("STATUS|fnum_read_failed")
    FileHandle.standardError.write("FNum unreadable\n".data(using: .utf8)!)
    exit(3)
}

let numFans = Int(fnumOut.bytes.0)
if numFans == 0 {
    emit("STATUS|fanless")
    exit(0)
}

emit("STATUS|ok")

for i in 0..<numFans {
    let acKey = fourCharCode("F\(i)Ac")
    let mxKey = fourCharCode("F\(i)Mx")

    // Both reads must succeed AND decode for the line to be emitted. The
    // prior implementation defaulted to 0 RPM on read failure (rendered as
    // "fan off") and fabricated 6500 RPM on max failure; both made silent
    // misreadings look like measurements.
    guard let acFrame = readSMCKey(conn, key: acKey),
          let rpm = decodeSMC(acFrame) else {
        FileHandle.standardError.write("F\(i)Ac read/decode failed\n".data(using: .utf8)!)
        continue
    }
    guard let mxFrame = readSMCKey(conn, key: mxKey),
          let maxRpm = decodeSMC(mxFrame), maxRpm > 0 else {
        FileHandle.standardError.write("F\(i)Mx read/decode failed\n".data(using: .utf8)!)
        continue
    }
    if !rpm.isFinite || !maxRpm.isFinite || rpm < 0 {
        continue
    }

    emit("FAN\(i)|\(String(format: "%.0f", rpm))|\(String(format: "%.0f", maxRpm))")
}
