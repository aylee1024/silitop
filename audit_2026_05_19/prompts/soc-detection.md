# silitop comprehensive audit — subject: soc-detection

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

Audit how silitop detects the SoC name, core counts, and core-tier
labels.

Files and ranges:
- `silitop` lines 36-128 (`get_soc_info`) plus the helper
  `_is_efficiency` at lines 199-201.

Read README for the documented tier labeling rules. The host is an
M5 Pro; the code must also work on M1/M2/M3/M4 base/Pro/Max/Ultra/Air.


## Out of scope (other codex agents own these — do NOT audit them here)

- Powermetrics plist parsing (covered by powermetrics-parsing).
- Curses rendering of the SoC label.


## What to audit for

- `sysctl` keys used: are `machdep.cpu.brand_string`, `hw.perflevel0.*`,
  `hw.perflevel1.*` the canonical Apple-Silicon names? Verify or label
  "I am estimating". List exactly what the code reads.
- Regex correctness for distinguishing M1, M2, M3, M4, M5 and the
  Pro/Max/Ultra/Air variants. Walk through the regex on at least these
  brand strings: "Apple M1", "Apple M1 Pro", "Apple M1 Max", "Apple M1
  Ultra", "Apple M2", ..., "Apple M5", "Apple M5 Pro". Note any that
  would mismatch or default-bucket incorrectly.
- Fallback when a sysctl key is missing (older macOS, virtualized host,
  hackintosh): does the function raise, return a sentinel, or guess?
- GPU core count: how is it obtained, and is it reliable across the
  M-series?
- Tier labels: README states M5 uses Super/Performance, M1-M4 use
  Efficiency/Performance. Walk the branching and confirm. Note the
  fast_prefix/slow_prefix output and ensure they pair with the labels
  consistently.
- `_is_efficiency`: what name patterns does it match against? Is it
  robust to Apple renaming clusters in a future kernel release?
- Detection of binned vs full chips (M3 Pro 11-core vs 12-core, etc.)
  if any code relies on it.


## Deliverable

Emit ONLY the report below. Do not write to disk; the watchdog captures stdout.

```
# silitop audit — soc-detection

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
