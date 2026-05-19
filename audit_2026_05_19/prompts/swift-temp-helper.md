# silitop comprehensive audit — subject: swift-temp-helper

## Pre-read (MANDATORY — read these in full before auditing)

1. `/Users/andrewlee/.claude/CLAUDE.md` — Andrew's universal rules. Honor:
   - Be critically honest. No sugarcoating, no hedging to be polite.
   - Explain mechanistically: what happens, step by step, with specifics.
   - When stating a number/threshold, cite the source or say "I am estimating".
   - Never guess facts. If uncertain, say so explicitly.
   - Sparingly use em-dashes; prefer commas, semicolons, parentheses.
2. `/Users/andrewlee/Desktop/Code/silitop/README.md` — project context.

## Project under audit

silitop is a CLI performance monitor for Apple Silicon Macs. Three executables collaborate:
- `silitop` (Python 3, curses UI, 1208 lines): `/Users/andrewlee/Desktop/Code/silitop/silitop`
- `silitop-temps.swift` (92 lines): `/Users/andrewlee/Desktop/Code/silitop/silitop-temps.swift`
- `silitop-fans.swift` (134 lines): `/Users/andrewlee/Desktop/Code/silitop/silitop-fans.swift`
- `install.sh` (64 lines): `/Users/andrewlee/Desktop/Code/silitop/install.sh`
- `tests/test_layout.py` (311 lines): `/Users/andrewlee/Desktop/Code/silitop/tests/test_layout.py`

silitop spawns `powermetrics` as a child (writes plist samples to `/tmp/silitop_pm*`),
shells out to `silitop-temps` and `silitop-fans` binaries each tick, parses
`vm_stat` and `sysctl`, and renders a curses dashboard. Requires `sudo` because
`powermetrics` does.

Today is 2026-05-19. The host this is built on is an M5 Pro MacBook Pro.

## Your scope

Audit `silitop-temps.swift` (92 lines) in full. This is the IOHID-
based temperature sensor reader.

File: `/Users/andrewlee/Desktop/Code/silitop/silitop-temps.swift`.


## Out of scope (other codex agents own these — do NOT audit them here)

- The Python caller that consumes its output (temp-classification).
- The fan helper (fan-reader).


## What to audit for

- IOHIDEventSystemClient: creation, ownership, and disposal. Is the
  client released on all exit paths?
- Matching dictionary: it presumably matches HIDPage `0xff00`
  (kHIDPage_AppleVendor) with HIDUsage `0x5` (temperature sensor).
  Verify the page/usage values and how the dict is built (CFNumber
  vs Swift Int bridging).
- Service enumeration: `IOHIDEventSystemClientCopyServices` returns
  CFArray of CFTypes. Are the array and its elements correctly
  retained/released under Swift ARC + Core Foundation?
- Sensor value extraction: `IOHIDServiceClientCopyEvent(client,
  kIOHIDEventTypeTemperature, 0, 0)` returns an HID event. Verify
  the event type integer used in the call.
- Unit conversion: HID temperature events return Celsius in
  IOHIDFloat (double). Confirm there is no double-conversion (e.g.
  accidental Kelvin->Celsius offset, or 0.01 scale that some
  code uses for SMC values).
- Sensor naming: how is the sensor name retrieved? `kIOHIDProperty
  ProductKey`? `kIOHIDServiceClientLocationKey`? What if name is
  nil? Does the helper still emit the line?
- Output buffering: are stdout lines flushed? If silitop reads
  stdout without setting a pty, swift's stdout is block-buffered.
- Error paths: exits nonzero or just prints nothing on failure?
  Distinguish from "no sensors present".
- macOS version constraints: does the API exist on macOS 12+?
  13+? Document the minimum.
- Concurrency: is the helper single-shot per silitop tick, or
  long-lived? Either way, are there issues if invoked rapidly?


## Deliverable

Emit ONLY the report below. Do not write to disk; the watchdog captures stdout.

```
# silitop audit — swift-temp-helper

## Summary
<one paragraph: the single most important finding, plus overall quality of the subsystem in your scope. Honest, not flattering.>

## Findings (ranked)

### CRIT-1: <short title>
- **Location:** `file:line` or `file:line_start-line_end`
- **Mechanism:** Step by step, what goes wrong and when.
- **Impact:** Observable user/system effect.
- **Repro:** How to trigger (commands, terminal size, chip, sensor present/absent, etc).
- **Fix sketch:** Concrete change with file:line. No speculative refactors.

### HIGH-1: ...

### MED-1: ...

### LOW-1: ...

## What I verified vs assumed
- Verified: <list of behaviors you actually traced through code>.
- Assumed: <list of behaviors you inferred but did not fully verify, with the assumption stated>.
- Did not look at: <anything in your scope you ran out of time on>.
```

## Severity definitions (use these consistently)

- **CRIT**: data corruption, incorrect readings the user trusts, crash on common path, security issue (privilege/escape/data exfil), or the agent silently degrades a reading to zero.
- **HIGH**: incorrect on a documented platform variant (M1/M2/M3/M4/M5/Air vs Pro), resource leak, hot-path inefficiency that wastes >10% CPU, missing error path that masks failure.
- **MED**: misleading label, off-by-one in cosmetic output, suboptimal fallback, fragile parser that will break on a future macOS, missing test for risky logic.
- **LOW**: style, dead code, redundant computation, naming, comment.

## Rules of engagement

- Cite `file:line` for every claim. No vague "somewhere in the parsing logic".
- If you cannot determine whether a thing is a bug without running it on hardware, say so explicitly under "Assumed" and label it HIGH, not CRIT.
- Quote at most 3 lines of code per finding to anchor it. The reader has the file.
- If the subsystem in your scope is actually well-built, say so plainly in the Summary. Pad nothing.
- No em-dashes as connectors; commas/semicolons/parens preferred.
- Do not propose architectural rewrites. Mark them as LOW: "consider X" if you must, but stay in scope.
