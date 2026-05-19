# silitop audit — swift-temp-helper

## Summary
The helper uses the right broad IOHID target, Apple vendor page `0xff00` plus temperature usage `0x5`, but its failure contract is broken: if every client type fails to produce a usable event, `silitop-temps.swift:92` falls off the end with exit status 0 and no stderr. Ownership is mostly acceptable for a short-lived single-shot helper, but the success path calls `exit(0)` before ARC can release the current client, and the temperature extraction path is too speculative for data the user will trust.

## Findings (ranked)

### HIGH-1: Empty failure exits as success
- **Location:** `silitop-temps.swift:39-50`, `silitop-temps.swift:61-85`, `silitop-temps.swift:89-92`
- **Mechanism:** The helper tries four client types. If `IOHIDEventSystemClientCopyServices` returns nil, line 50 just continues. If services exist but `IOHIDServiceClientCopyEvent` returns nil, or every extracted value fails the `temp > 0 && temp < 150` gate, no line is printed. After the loop, there is no failure branch, so Swift reaches EOF at line 92 and exits 0.
- **Impact:** The caller cannot distinguish "no sensors present" from "IOHID failed", "wrong event field", "no permission", or "unsupported macOS behavior". That masks a total temperature-reader failure.
- **Repro:** On this host, `/usr/local/bin/silitop-temps; echo $?` produced no stdout and exit 0. I could not prove that installed binary was rebuilt from this exact source; the source path itself still has the same EOF-success behavior.
- **Fix sketch:** Around `silitop-temps.swift:39`, track `matchedServices`, `eventsSeen`, and `linesEmitted`. Replace the EOF fallthrough at `silitop-temps.swift:92` with a stderr diagnostic and nonzero exit when `linesEmitted == 0`. Also make the create calls optional so a null client becomes a controlled error instead of an implicit crash.

### HIGH-2: Temperature reads an undocumented field before the known temperature field
- **Location:** `silitop-temps.swift:61-80`
- **Mechanism:** The helper calls `IOHIDServiceClientCopyEvent(..., 15, 0, 0)` correctly, but then first reads field `0x000F0001` at line 63. The known field base for event type 15 is `15 << 16`, which is `0x000F0000`; the helper only falls back to that field if the first read is outside `0...150`. If `0x000F0001` returns any plausible non-temperature value, the helper prints it as Celsius.
- **Impact:** Potentially incorrect temperatures that look valid. I did not verify that `0x000F0001` returns a plausible value on this M5 Pro, so this is HIGH rather than CRIT.
- **Repro:** Run a build that logs both fields for a service, compare `IOHIDEventGetFloatValue(event, 0x000F0001)` with `IOHIDEventGetFloatValue(event, 0x000F0000)`. Chromium’s M1 sensor reader uses the base field, not base+1.
- **Fix sketch:** Replace `silitop-temps.swift:62-80` with a single base-field read:
  `let temp = IOHIDEventGetFloatValue(event, UInt32(kIOHIDEventTypeTemperature << 16))`.
  Keep the plausibility gate at `silitop-temps.swift:82`.

### MED-1: Product-name dedupe silently drops distinct sensors
- **Location:** `silitop-temps.swift:53-59`
- **Mechanism:** The helper dedupes only on `Product`. It inserts the name into `seen` before confirming the service has a valid temperature event. Distinct services with the same Product, or multiple nil names collapsed to `"Unknown"`, cause later services to be skipped.
- **Impact:** Raw sensor output can omit real sensors. On this M5 Pro, `ioreg -lw0 -r -c IOHIDEventService` shows multiple Apple vendor temperature services with the same Product, including repeated `"gas gauge battery"` entries with different `LocationID` values.
- **Repro:** Run `ioreg -lw0 -r -c IOHIDEventService | grep -E '"Product"|"PrimaryUsage"|"PrimaryUsagePage"|"LocationID"'` and compare duplicate Products against helper output.
- **Fix sketch:** At `silitop-temps.swift:56-59`, include `LocationID` or registry ID in the identity key, or remove helper-level dedupe. If Product is nil, emit a stable fallback such as `Unknown@<LocationID>`.

### LOW-1: Success path bypasses ARC cleanup for the current IOHID client
- **Location:** `silitop-temps.swift:39-45`, `silitop-temps.swift:89-90`
- **Mechanism:** `IOHIDEventSystemClientCreate` and `IOHIDEventSystemClientCreateWithType` are consumed with `takeRetainedValue`, so ARC should release them when the local scope ends. On success, line 90 calls `exit(0)` from inside that scope; Swift local destructors are not run before process termination.
- **Impact:** No persistent leak across invocations because the OS reclaims the process, but the client is not released on all exit paths.
- **Repro:** Code inspection. The only explicit success exit is `exit(0)` inside the loop.
- **Fix sketch:** Replace `exit(0)` at `silitop-temps.swift:90` with a labeled `break`, then let the top-level scope end normally. If explicit status is needed, wrap the loop in `main() -> Int32` and call `exit(main())` after locals are gone.

## What I verified vs assumed
- Verified: Read `/Users/andrewlee/.claude/CLAUDE.md`, `README.md`, and `silitop-temps.swift` in full.
- Verified: `silitop-temps.swift:31-34` uses `PrimaryUsagePage = 0xff00` and `PrimaryUsage = 5`; Chromium’s internal M1 sensor definitions identify these as Apple vendor and temperature sensor: https://chromium.googlesource.com/chromium/src/+/c21e9f71d1f2e/components/power_metrics/m1_sensors_internal_types_mac.h
- Verified: `kIOHIDEventTypeTemperature = 15` and field base `type << 16` match Chromium’s implementation: https://chromium.googlesource.com/chromium/src/+/112.0.5615.165/components/power_metrics/m1_sensors_mac.mm
- Verified: Local SDK headers define `kIOHIDProductKey` as `"Product"` and `kIOHIDLocationIDKey` as `"LocationID"`.
- Verified: Local IOKit `.tbd` files for SDKs 14.5, 15.5, and 26.2 export the IOHID symbols used here.
- Assumed: Swift `[String: Int] as CFDictionary` bridges values to CFNumber in the form IOHID matching accepts; I could not compile Swift in the read-only sandbox.
- Assumed: IOHID temperature event values are Celsius doubles; this is inferred from Chromium and btop-style implementations, not Apple public docs.
- Did not look at: The Python caller’s temperature classification, the fan helper, or full macOS 12/13 runtime availability.