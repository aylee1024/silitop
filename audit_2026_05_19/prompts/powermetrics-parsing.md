# silitop comprehensive audit — subject: powermetrics-parsing

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

Audit how silitop spawns `powermetrics`, watches it write plist samples to
`/tmp/silitop_pm*`, and extracts CPU/GPU/thermal/network/disk fields.

Files and ranges:
- `silitop` lines 129-289 covering `run_powermetrics`, `parse_powermetrics`,
  `_is_efficiency`, `extract_cpu`, `extract_gpu`, `extract_thermal`,
  `extract_network`, `extract_disk`, `format_rate`, and `_find_helper`.

Read the rest of `silitop` only as needed to follow call sites.


## Out of scope (other codex agents own these — do NOT audit them here)

- `get_soc_info` (covered by soc-detection agent).
- Temperature *labeling* and sensor classification (covered by
  temp-classification agent). You DO own how thermal pressure is
  extracted from the plist itself.
- Curses rendering of the parsed values.
- `subprocess` security or `/tmp` race conditions (covered by safety-security).
  You can still note "this open() is racy" but do not duplicate the deep audit.


## What to audit for

- Plist key access correctness: are the dictionary keys silitop reads
  (e.g. `processor.clusters`, `cpu_frequency_hz`, `pcpu_active_ratio`,
  `gpu.freq_hz`, `network.ibyte_rate`, etc.) the actual keys produced by
  `powermetrics -f plist -s cpu_power,gpu_power,thermal,network,disk`?
  You must verify against the actual schema if you can; otherwise say
  "I am estimating, based on shape of code". Do not invent keys.
- Unit handling: is `cpu_frequency_hz` Hz, kHz, or already MHz? Does
  `format_rate` correctly map bytes-per-second to KB/MB/GB/s? Check the
  divisor used.
- Missing-key behavior: when a key is absent (e.g. on chips with no ANE,
  or no fan, or a release where Apple renamed a key), does the code raise,
  silently fall through, or return a misleading zero?
- Multiple-samples-per-file: does `parse_powermetrics` correctly handle
  the case where `powermetrics` writes multiple plist samples into the
  same file between reads?
- Plist file rotation: how is the `timecode` used to find the latest
  sample? Are stale files cleaned up?
- `_find_helper`: does the search path for the Swift helpers handle the
  install case (`/usr/local/bin`) AND the dev case (running from the
  repo)? What if both exist?
- Numeric edge cases: division by zero, negative deltas (counter
  wraparound), NaN propagation.
- `extract_cpu` cluster iteration: what if cluster count != expected
  for the SoC family?


## Deliverable

Emit ONLY the report below. Do not write to disk; the watchdog captures stdout.

```
# silitop audit — powermetrics-parsing

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
