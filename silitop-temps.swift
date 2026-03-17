import Foundation
import IOKit

// Try multiple IOHIDEventSystemClient creation methods
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

@_silgen_name("IOHIDEventGetIntegerValue")
func IOHIDEventGetIntegerValue(_ event: AnyObject, _ field: UInt32) -> Int64

let kIOHIDEventTypeTemperature: Int64 = 15

let matching = [
    "PrimaryUsagePage": 0xFF00,
    "PrimaryUsage": 5
] as CFDictionary

// Try client types: 0 = monitor, 1 = passive, 2 = rate-controlled, 3 = simple
let clientTypes: [Int32] = [0, 1, 2, 3]

for clientType in clientTypes {
    let system: AnyObject
    if clientType == 0 {
        system = IOHIDEventSystemClientCreate(kCFAllocatorDefault).takeRetainedValue()
    } else {
        system = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, clientType, nil).takeRetainedValue()
    }
    
    IOHIDEventSystemClientSetMatching(system, matching)
    
    guard let services = IOHIDEventSystemClientCopyServices(system)?.takeRetainedValue() as? [AnyObject] else {
        continue
    }
    
    var seen = Set<String>()
    var foundAny = false
    for service in services {
        let nameRef = IOHIDServiceClientCopyProperty(service, "Product" as CFString)
        let name = nameRef?.takeRetainedValue() as? String ?? "Unknown"
        if seen.contains(name) { continue }
        seen.insert(name)
        
        if let event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0)?.takeRetainedValue() {
            // Try both field constants
            let temp1 = IOHIDEventGetFloatValue(event, 0x000F0001)
            let temp2 = IOHIDEventGetFloatValue(event, 0x000F0000)
            let temp3 = IOHIDEventGetIntegerValue(event, 0x000F0001)
            
            // Use whichever returns a plausible temperature
            var temp = temp1
            if temp <= 0 || temp > 150 {
                // Check if temp2 makes sense as fixed-point
                if temp2 > 0 && temp2 < 150 {
                    temp = temp2
                } else if temp3 > 0 && temp3 < 150000 {
                    // Might be millidegrees
                    temp = Double(temp3) / 1000.0
                    if temp <= 0 || temp > 150 {
                        temp = Double(temp3)
                    }
                }
            }
            
            if temp > 0 && temp < 150 {
                print("\(name)|\(String(format: "%.1f", temp))")
                foundAny = true
            }
        }
    }
    
    if foundAny {
        exit(0) // Found working client type
    }
}
