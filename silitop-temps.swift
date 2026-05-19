import Foundation
import IOKit

// silitop-temps v1
//
// Protocol (stdout, line-delimited UTF-8):
//   silitop-temps v1
//   STATUS|ok | STATUS|no_sensors_found | STATUS|client_unavailable
//   <sensor_name>|<celsius>    (only when STATUS|ok; one per sensor)
//
// Exit codes:
//   0 = STATUS|ok (one or more sensors found)
//   2 = STATUS|no_sensors_found (every client type returned 0 sensors after
//                                exhausting the type list)
//   3 = STATUS|client_unavailable (every client type returned a nil client)
//
// The prior implementation exited 0 with no stdout on total failure, making
// "no sensors present" indistinguishable from "IOHID broken / wrong macOS".
// The Python parser used to swallow this as `{}` and hide the temperature
// pane silently. Under the v1 protocol the caller can distinguish version
// mismatch (None -> render unavailable banner) from a successful empty
// result (e.g., a sandboxed environment that legitimately exposes nothing).

@_silgen_name("IOHIDEventSystemClientCreate")
func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>

@_silgen_name("IOHIDEventSystemClientCreateWithType")
func IOHIDEventSystemClientCreateWithType(_ allocator: CFAllocator?, _ type: Int32, _ properties: CFDictionary?) -> Unmanaged<AnyObject>

@_silgen_name("IOHIDEventSystemClientSetMatching")
func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary)

@_silgen_name("IOHIDEventSystemClientCopyServices")
func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDServiceClientCopyEvent")
func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ matching: Int64, _ options: Int64) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventGetFloatValue")
func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: UInt32) -> Double

let kIOHIDEventTypeTemperature: Int64 = 15
// IOHID event field index: <type << 16> | <field_id>. The base field
// (field_id=0) is the documented temperature value. The prior implementation
// preferred 0x000F0001 (field_id=1, undocumented) and only fell back to base
// on out-of-range output; this could yield plausible-looking but non-Celsius
// readings. Chromium's m1_sensors_mac.mm uses the base field exclusively.
let kIOHIDEventFieldTemperatureValue: UInt32 = UInt32(kIOHIDEventTypeTemperature) << 16

let matching = [
    "PrimaryUsagePage": 0xFF00,
    "PrimaryUsage": 5
] as CFDictionary

// Try client types: 0 = default, 1 = passive, 2 = rate-controlled, 3 = simple
let clientTypes: [Int32] = [0, 1, 2, 3]

func emit(_ line: String) {
    print(line)
}

emit("silitop-temps v1")

var anyClientReachable = false
var linesEmitted = 0

for clientType in clientTypes {
    let client: AnyObject? = {
        if clientType == 0 {
            return IOHIDEventSystemClientCreate(kCFAllocatorDefault).takeRetainedValue()
        }
        return IOHIDEventSystemClientCreateWithType(
            kCFAllocatorDefault, clientType, nil
        ).takeRetainedValue()
    }()
    guard let system = client else { continue }
    anyClientReachable = true

    IOHIDEventSystemClientSetMatching(system, matching)

    guard let services = IOHIDEventSystemClientCopyServices(system)?
        .takeRetainedValue() as? [AnyObject] else {
        continue
    }

    // Dedupe by (Product, LocationID) instead of Product alone so we don't
    // collapse multiple physical sensors that share a Product name. The
    // prior dedupe dropped distinct batteries, multiple temp sensors with
    // the same Product, and "Unknown" entries to a single line.
    var seen = Set<String>()
    for service in services {
        let nameRef = IOHIDServiceClientCopyProperty(service, "Product" as CFString)
        let name = (nameRef?.takeRetainedValue() as? String) ?? "Unknown"
        let locRef = IOHIDServiceClientCopyProperty(service, "LocationID" as CFString)
        let loc = (locRef?.takeRetainedValue() as? NSNumber).map { "@\($0.uint64Value)" } ?? ""
        let key = name + loc
        if seen.contains(key) { continue }
        seen.insert(key)

        guard let event = IOHIDServiceClientCopyEvent(
                service, kIOHIDEventTypeTemperature, 0, 0
        )?.takeRetainedValue() else {
            continue
        }
        let temp = IOHIDEventGetFloatValue(event, kIOHIDEventFieldTemperatureValue)
        if temp > 0 && temp < 150 {
            // Sensor names with literal '|' are sanitized so the Python parser's
            // split() doesn't drop the line. None are expected from IOHID today
            // but we don't want a future Apple rename to silently break parsing.
            let safeName = name.replacingOccurrences(of: "|", with: "/")
            emit("\(safeName)|\(String(format: "%.1f", temp))")
            linesEmitted += 1
        }
    }

    if linesEmitted > 0 { break }
}

if linesEmitted > 0 {
    emit("STATUS|ok")
    exit(0)
}
if !anyClientReachable {
    emit("STATUS|client_unavailable")
    FileHandle.standardError.write(
        "no IOHIDEventSystemClient creation succeeded\n".data(using: .utf8)!)
    exit(3)
}
emit("STATUS|no_sensors_found")
FileHandle.standardError.write(
    "all client types returned 0 sensors\n".data(using: .utf8)!)
exit(2)
