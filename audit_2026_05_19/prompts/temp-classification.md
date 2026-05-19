# silitop comprehensive audit — subject: temp-classification

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

Audit how silitop reads die-temperature sensors via the
`silitop-temps` Swift helper and classifies them into CPU/GPU/SSD/
battery zones.

Files and ranges:
- `silitop` lines 313-396 (`read_hid_temps`, `SENSOR_LABELS`,
  `classify_temps`).
- You may glance at `silitop-temps.swift` ONLY to confirm the output
  format Python parses. The Swift implementation itself is owned by
  the swift-temp-helper agent.


## Out of scope (other codex agents own these — do NOT audit them here)

- The Swift helper's IOKit/IOHID internals (swift-temp-helper).
- The Python<->Swift output contract semantics (interface-contracts).
  You can still flag a missed line in your parser; just don't redo the
  full contract analysis.


## What to audit for

- `read_hid_temps`: subprocess invocation, timeout behavior, exit-code
  handling, stderr behavior, empty-output behavior. Does it cache
  between ticks or shell out every refresh?
- Output parser: assumes lines of form `name|temp`. What happens on
  malformed lines, blank lines, non-ASCII names, names containing `|`,
  or a missing trailing newline?
- `SENSOR_LABELS` map: list which raw sensor names it normalizes and
  which it discards. Is the map specific to M5 Pro or general?
- `classify_temps`: walk the heuristic that splits the sensor list into
  CPU vs GPU vs SSD vs battery zones. README mentions "14 die zones"
  and acknowledges per-core mapping is unsolved. Is the current
  heuristic biased toward any chip?
- `gpu_die_zones=2` default: where does this number come from? Does it
  break on Max/Ultra chips that have more GPU dies?
- Empty-sensor-list path: if the helper returns nothing (e.g. on an
  older OS or non-Pro chip), does silitop crash, hide the temp pane,
  or render zeros?


## Deliverable

Emit ONLY the report below. Do not write to disk; the watchdog captures stdout.

```
# silitop audit — temp-classification

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
