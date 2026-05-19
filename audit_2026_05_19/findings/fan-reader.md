# silitop audit — fan-reader

## Summary
The most important bug is that the Swift helper can turn SMC read failures, and likely `fpe2`-encoded RPM values, into plausible `0` RPM output that Python accepts as real. The lifecycle handling is partly clean on the normal path, but the subsystem is too silent on errors: fanless, helper failure, AppleSMC failure, and malformed SMC values collapse into “no fans” or “fan off.”

## Findings (ranked)

### CRIT-1: Failed current-RPM reads are reported as real zero RPM
- **Location:** `silitop-fans.swift:119-124`, `silitop-fans.swift:129-133`, `silitop:341-348`, `silitop:913-920`
- **Mechanism:** `rpm` starts at `0`. If `readSMCKey(conn, key: acKey)` fails, the `if let` body is skipped and `rpm` stays `0`. The helper then prints `FAN<n>|0|<max>`. Python parses that as a valid fan record, and the UI path treats `rpm == 0` as “off.”
- **Impact:** A read failure becomes a trusted fan reading. On a fan-equipped Mac, silitop can show a stopped/off fan instead of surfacing that the fan read failed.
- **Repro:** Make `F0Ac` unreadable or unsupported while `FNum` and `F0Mx` still read, or stub the helper to print `FAN0|0|6500`. The Python path accepts it and renders the fan as off.
- **Fix sketch:** In `silitop-fans.swift:122-124`, do not default failed current RPM reads to `0`. Skip that fan or exit nonzero with stderr. In `silitop:333-353`, distinguish helper failure from a valid zero RPM reading.

### HIGH-1: SMC value decoder ignores `fpe2`, so RPM can decode as zero or garbage
- **Location:** `silitop-fans.swift:23-26`, `silitop-fans.swift:82-92`, `silitop-fans.swift:95-102`, `silitop-fans.swift:122-126`
- **Mechanism:** The helper fetches `keyInfo.dataType`, but then decodes every value with `bytesToFloat`. For `fpe2`, the correct shape is a 16-bit fixed-point integer with 2 fractional bits, not a 32-bit IEEE float. A normal `fpe2` value like 2000 RPM is encoded as `8000 / 4`; reinterpreting the first bytes as a float produces a tiny non-RPM float that formats as `0`.
- **Impact:** On any platform where `F<n>Ac` or `F<n>Mx` is `fpe2`, RPM and max RPM are wrong. The common observable failure is `0` RPM, which then looks like a real stopped fan.
- **Repro:** Run on a machine whose fan keys report `fpe2`, or unit-test `bytesToFloat` with fpe2 bytes for 2000 RPM (`0x1f, 0x40`). The helper will not return `2000`.
- **Fix sketch:** Preserve the key info from step 1 in `readSMCKey` before returning. Add a decoder at `silitop-fans.swift:95` that switches on `dataType`: `fpe2` should decode `((UInt16(b0) << 8) | UInt16(b1)) / 4.0`; `flt ` can use a float decoder.

### HIGH-2: First empty helper result disables fan reads forever
- **Location:** `silitop:333-353`, `silitop:816-821`, `silitop-fans.swift:107-113`
- **Mechanism:** The Swift helper exits `0` with no output for AppleSMC open failure, `FNum` read failure, and `FNum == 0`. Python also catches all helper exceptions and returns `[]`. On the first empty result, `fan_seen` is false, so `fan_available` becomes false and silitop never calls the helper again.
- **Impact:** A transient helper failure on a fan-equipped Mac permanently removes fan display for the process lifetime. It is indistinguishable from a genuinely fanless MacBook Air.
- **Repro:** Start silitop when the first `silitop-fans` call returns empty stdout, times out, or exits nonzero. On this audit host, running both compiled helpers produced empty stdout and exit `0`, but the code makes the exact cause unobservable.
- **Fix sketch:** In `silitop-fans.swift:107` and `111`, exit nonzero for AppleSMC open/read failures; reserve empty `exit(0)` for confirmed `FNum == 0`. In `silitop:333-353`, return `None` for helper failure and `[]` for confirmed no-fan output; only set `fan_available = False` for the confirmed no-fan case.

### HIGH-3: `exit(0)` skips the deferred AppleSMC close on error and fanless paths
- **Location:** `silitop-fans.swift:107-113`
- **Mechanism:** The connection is opened at line 107 and scheduled for close with `defer` at line 108. The later `exit(0)` calls at lines 111 and 113 terminate the process instead of leaving the Swift scope normally, so the deferred `IOServiceClose(conn)` does not run.
- **Impact:** The normal successful path closes the connection, but `FNum` read failure and confirmed fanless paths do not close it explicitly. Process exit should reclaim the Mach port, but the IOKit lifecycle is still wrong in source.
- **Repro:** Run on a fanless platform where `FNum == 0`, or force the `FNum` read to fail after `openSMC()` succeeds.
- **Fix sketch:** Replace those `exit(0)` calls with control flow that reaches the end of the top-level scope, or call `IOServiceClose(conn)` before exiting. Keep `IOObjectRelease(service)` at `silitop-fans.swift:62`; that part is correct.

### MED-1: Failed max-RPM reads use an uncited hardcoded `6500`
- **Location:** `silitop-fans.swift:120-131`, `silitop:908-910`
- **Mechanism:** `maxRpm` starts at `0`. If `F<n>Mx` cannot be read, the helper silently substitutes `6500`. Python then computes `int(rpm / max_rpm * 100)` as if `6500` were measured.
- **Impact:** The RPM may be real, but the percentage is fabricated. On fans whose max is not 6500 RPM, the fan bar percentage is wrong.
- **Repro:** Make `F0Mx` fail while `F0Ac` succeeds. The helper still prints a valid-looking line with max RPM `6500`.
- **Fix sketch:** In `silitop-fans.swift:125-131`, treat missing max RPM as missing data, not as a measured value. Either omit the fan record or print a sentinel that Python does not use for percentage computation.

### MED-2: Python accepts NaN and infinity, then can crash in percent conversion
- **Location:** `silitop:341-348`, `silitop:908-910`, `silitop:647-654`
- **Mechanism:** `float(parts[1])` and `float(parts[2])` accept `nan`, `inf`, and `-inf`. If `rpm` is `nan` and `max_rpm > 0`, `int(rpm / max_rpm * 100)` raises. If `rpm` is infinite, `int(inf)` also raises later.
- **Impact:** A malformed helper line can crash the curses loop instead of being ignored.
- **Repro:** Stub `silitop-fans` to print `FAN0|nan|6500` or `FAN0|inf|6500`.
- **Fix sketch:** In `silitop:345-348`, validate `math.isfinite(rpm)`, `math.isfinite(max_rpm)`, `rpm >= 0`, and `max_rpm > 0` before appending the fan record.

## What I verified vs assumed
- Verified: `AppleSMC` service lookup uses `IOServiceGetMatchingService`, and the service object is released after `IOServiceOpen` at `silitop-fans.swift:56-63`.
- Verified: The helper opens AppleSMC once per invocation at `silitop-fans.swift:107`, then reuses the same connection for `FNum`, `F<n>Ac`, and `F<n>Mx`.
- Verified: Each SMC key read performs two `IOConnectCallStructMethod` calls, key info then value, at `silitop-fans.swift:69-90`.
- Verified: Python polls fans every third loop while enabled, not every render pass, at `silitop:813-821`. With the default `--interval 1` at `silitop:1180-1181`, that is about one helper launch every 3 seconds.
- Verified: For `N` fans, the helper does `2 + 4N` SMC struct calls per poll. Assuming 2 fans, that is 10 SMC calls plus one process launch per poll. I estimate this is well below 10% CPU, but I did not measure CPU cost.
- Verified: `FNum == 0` prints nothing and exits successfully, and Python handles empty output by not showing a fake `0` RPM fan.
- Assumed: `exit(0)` bypasses Swift `defer`; I did not run a Swift probe because the sandbox is read-only and Swift attempted to create cache files.
- Assumed: Some target fan RPM keys use `fpe2`, based on the audit prompt’s stated SMC formats. I did not verify the target M5 Pro key `dataType` at runtime because the helper does not print key info.
- Did not look at: Temperature reading, fan-bar rendering aesthetics, SoC detection, or install-time behavior beyond helper location and invocation.