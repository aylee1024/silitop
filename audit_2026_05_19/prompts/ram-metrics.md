# silitop comprehensive audit — subject: ram-metrics

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

Audit `get_ram_metrics` and any helpers it uses.

Files and ranges:
- `silitop` lines 397-480 (`get_ram_metrics`). Read the surrounding
  callers (in `main`) to understand how the result is consumed, but
  do not audit the curses render here.


## Out of scope (other codex agents own these — do NOT audit them here)

- Curses rendering of the memory bar.
- Total-memory detection via `hw.memsize` IF it overlaps soc-detection;
  just note overlap and continue.


## What to audit for

- `vm_stat` output parsing. The header line on macOS reports page size
  (e.g. "Mach Virtual Memory Statistics: (page size of 16384 bytes)").
  Apple Silicon uses 16K pages. Does the code parse the dynamic page
  size from the header, or hardcode 4096? A hardcoded 4096 would
  underreport memory by 4x.
- vm_stat field extraction: lines like "Pages free:", "Pages active:",
  "Pages wired down:", "Pages occupied by compressor:". Is the regex
  tolerant of macOS version differences? What about "Pages purgeable",
  "Pages speculative"?
- Swap stats: `sysctl vm.swapusage` parses to a string like
  "total = 0.00M  used = 0.00M  free = 0.00M  (encrypted)". Walk the
  parser.
- `hw.memsize` sysctl: verify the units (bytes).
- Classification: how does the code split pages into wired vs active
  vs inactive vs compressed vs free? Is the "used" definition
  consistent with what Activity Monitor shows? (Apple uses
  wired + active + compressed; macOS aggregates inactive as a
  separate "cached files" bucket.)
- Edge cases: what if `vm_stat` returns no output (sandboxed shell)?
  What if a line is missing entirely?
- Hot-path cost: how often is `get_ram_metrics` called and how many
  subprocesses does it spawn per tick?


## Deliverable

Emit ONLY the report below. Do not write to disk; the watchdog captures stdout.

```
# silitop audit — ram-metrics

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
