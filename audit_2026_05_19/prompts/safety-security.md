# silitop comprehensive audit — subject: safety-security

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

Audit safety and security of the whole pipeline.

Files and ranges (read these specifically):
- Every `subprocess.*` call site in `silitop`.
- Every `open(...)` and `os.path.*` call site involving `/tmp/`.
- `install.sh` for sudo/path/permission issues that overlap with
  install-script; cite that agent if so.
- The Swift helpers for any IPC or filesystem access.


## Out of scope (other codex agents own these — do NOT audit them here)

- Logical correctness of parsers (other agents).
- Code style.


## What to audit for

- Subprocess argv construction: is `shell=False` (or omitted) in
  every call? Any user input concatenated into argv? Any
  `os.system`, `os.popen`?
- `/tmp/silitop_pm*` path safety: predictable name, no `mkstemp`?
  If predictable, an attacker who can write to `/tmp` can pre-create
  a symlink and redirect silitop's plist read to another file. Walk
  the attack.
- PID-based or random suffix on the temp file? If absent, what
  happens with multiple users running silitop on the same host?
- Stale `/tmp/silitop_pm*` from a previous crashed run: silitop
  would read attacker-controlled content if the prefix collides.
  Real risk on multi-user macOS hosts? Note that `sudo silitop`
  runs as root, so a root read of a user-controlled `/tmp` file is
  a privilege issue.
- File mode on the plist temp file: 0600? 0644? Is the parent
  directory `/tmp` (sticky) sufficient?
- PowerMetrics elevation: silitop is run with sudo, so it spawns
  powermetrics as root. Are the Swift helpers also invoked as root?
  That is unavoidable but worth flagging if they read arbitrary
  user files.
- Helper-binary path: `_find_helper` will search candidate paths.
  If the search picks up a binary from a user-writable directory
  (e.g. `./silitop-temps` in the cwd), root will execute attacker-
  controlled code. Walk the search order.
- Plist parsing: `plistlib.load` on attacker-controlled input is
  relatively safe (no plist-bomb in CPython), but confirm.
- `vm_stat`, `sysctl`, `powermetrics` are invoked by basename or
  absolute path? PATH-poisoning angle.
- Sudo footgun: any way for a non-root user to influence what root
  executes after `sudo silitop`?
- Resource exhaustion: bounded buffer sizes on deques / logs?


## Deliverable

Emit ONLY the report below. Do not write to disk; the watchdog captures stdout.

```
# silitop audit — safety-security

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
