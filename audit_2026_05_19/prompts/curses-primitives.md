# silitop comprehensive audit — subject: curses-primitives

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

Audit silitop's curses drawing primitives.

Files and ranges:
- `silitop` lines 481-721 covering `init_colors`, `hbar`, `clamp_pct`,
  `compute_bar_layout`, `temp_color`, `draw_box`, `safe_addstr`,
  `draw_core_row`, `draw_fan_row`, `draw_hbar_full`, `draw_spark`.
- `tests/test_layout.py` to see which of these are unit-tested and
  with what assertions.


## Out of scope (other codex agents own these — do NOT audit them here)

- The main render loop (main-loop-lifecycle).
- Color choice / scheme aesthetics.


## What to audit for

- `hbar` block-character math: it uses the 8-step partial block
  sequence `" ▏▎▍▌▋▊▉█"`. Verify the index math at the boundary
  (pct=0, pct=1.0, pct=0.999, pct slightly negative). Off-by-one in
  the partial column is a real risk.
- Unicode column width: do these block chars all return width 1 from
  `wcwidth`/curses? If any are width 2 on some terminals, the bar
  overflows.
- `clamp_pct`: covers `None`, `nan`, negative, >1?
- `compute_bar_layout`: walks total_width, pct, label, suffix. Off-by-
  one at tiny widths (e.g. width 5 with a 6-char label).
- `temp_color`: thresholds 50, 70 from README. Are the comparisons
  `<` vs `<=` consistent with the README text "cyan < 50C, yellow
  50-70C, red > 70C"?
- `safe_addstr`: clipping on `clip_right`, handling of strings that
  extend past the window edge, encoding (curses raises on non-ASCII
  if the locale is wrong; is the locale set?).
- `draw_box`: corner/edge characters, attr leak (does it leave the
  attribute active for subsequent draws?).
- `draw_spark`: empty `values` list, `max_val=0`, deque sized
  different from `w`, value > max_val.
- `init_colors`: number of color pairs allocated, foreground/back-
  ground tuples, init_pair indices reused vs collide.
- Coverage gap: which functions have no test?


## Deliverable

Emit ONLY the report below. Do not write to disk; the watchdog captures stdout.

```
# silitop audit — curses-primitives

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
