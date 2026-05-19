#!/usr/bin/env python3
"""Generate 12 codex audit prompts for silitop and stage their run_dirs."""
import os
import pathlib
import shutil
import textwrap

REPO = pathlib.Path.home() / "Desktop/Code/silitop"
AUDIT = REPO / "audit_2026_05_19"
PROMPTS_DIR = AUDIT / "prompts"
RUNS_BASE = pathlib.Path("/tmp/codex_runs")

PROMPTS_DIR.mkdir(parents=True, exist_ok=True)
RUNS_BASE.mkdir(parents=True, exist_ok=True)

COMMON_HEADER = """\
# silitop comprehensive audit — subject: {subject}

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

{scope}

## Out of scope (other codex agents own these — do NOT audit them here)

{out_of_scope}

## What to audit for

{dimensions}

## Deliverable

Emit ONLY the report below. Do not write to disk; the watchdog captures stdout.

```
# silitop audit — {subject}

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
"""

SUBJECTS = [
    {
        "subject": "powermetrics-parsing",
        "scope": textwrap.dedent("""\
            Audit how silitop spawns `powermetrics`, watches it write plist samples to
            `/tmp/silitop_pm*`, and extracts CPU/GPU/thermal/network/disk fields.

            Files and ranges:
            - `silitop` lines 129-289 covering `run_powermetrics`, `parse_powermetrics`,
              `_is_efficiency`, `extract_cpu`, `extract_gpu`, `extract_thermal`,
              `extract_network`, `extract_disk`, `format_rate`, and `_find_helper`.

            Read the rest of `silitop` only as needed to follow call sites.
        """),
        "out_of_scope": textwrap.dedent("""\
            - `get_soc_info` (covered by soc-detection agent).
            - Temperature *labeling* and sensor classification (covered by
              temp-classification agent). You DO own how thermal pressure is
              extracted from the plist itself.
            - Curses rendering of the parsed values.
            - `subprocess` security or `/tmp` race conditions (covered by safety-security).
              You can still note "this open() is racy" but do not duplicate the deep audit.
        """),
        "dimensions": textwrap.dedent("""\
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
        """),
    },
    {
        "subject": "soc-detection",
        "scope": textwrap.dedent("""\
            Audit how silitop detects the SoC name, core counts, and core-tier
            labels.

            Files and ranges:
            - `silitop` lines 36-128 (`get_soc_info`) plus the helper
              `_is_efficiency` at lines 199-201.

            Read README for the documented tier labeling rules. The host is an
            M5 Pro; the code must also work on M1/M2/M3/M4 base/Pro/Max/Ultra/Air.
        """),
        "out_of_scope": textwrap.dedent("""\
            - Powermetrics plist parsing (covered by powermetrics-parsing).
            - Curses rendering of the SoC label.
        """),
        "dimensions": textwrap.dedent("""\
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
        """),
    },
    {
        "subject": "temp-classification",
        "scope": textwrap.dedent("""\
            Audit how silitop reads die-temperature sensors via the
            `silitop-temps` Swift helper and classifies them into CPU/GPU/SSD/
            battery zones.

            Files and ranges:
            - `silitop` lines 313-396 (`read_hid_temps`, `SENSOR_LABELS`,
              `classify_temps`).
            - You may glance at `silitop-temps.swift` ONLY to confirm the output
              format Python parses. The Swift implementation itself is owned by
              the swift-temp-helper agent.
        """),
        "out_of_scope": textwrap.dedent("""\
            - The Swift helper's IOKit/IOHID internals (swift-temp-helper).
            - The Python<->Swift output contract semantics (interface-contracts).
              You can still flag a missed line in your parser; just don't redo the
              full contract analysis.
        """),
        "dimensions": textwrap.dedent("""\
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
        """),
    },
    {
        "subject": "fan-reader",
        "scope": textwrap.dedent("""\
            Audit how silitop reads fan RPM. Covers BOTH the Python side and the
            Swift helper.

            Files and ranges:
            - `silitop` lines 333-355 plus the `read_fan_speeds` helper (find the
              function and its callers).
            - `silitop-fans.swift` (entire file, 134 lines).
        """),
        "out_of_scope": textwrap.dedent("""\
            - Temperature reading (temp-classification, swift-temp-helper).
            - Curses rendering of the fan bar.
            - Detection of which chip is present (soc-detection).
        """),
        "dimensions": textwrap.dedent("""\
            - Swift IOKit lifecycle: is `AppleSMC` opened and the connection
              closed in all paths (including error)? Are IOKit objects released?
              Watch for `IORegistryEntryFromPath`, `IOServiceOpen`, and the
              matching close/release.
            - SMC key encoding: the Swift helper presumably reads `FNum`, `F<n>Ac`,
              `F<n>Mx` (current and max RPM per fan). Verify the key construction
              and the FourCC packing.
            - SMC value decoding: SMC numeric values come back as `fpe2` (16-bit
              fixed-point with 2 fractional bits) or `flt ` (IEEE float). Verify
              the decoder. A wrong decoder gives RPM off by 4x or by scaling.
            - Fan-less platforms (MacBook Air M1/M2/M3): what happens when
              `FNum == 0`? Does the helper exit clean, print nothing, or error?
              Does the Python caller handle empty output without showing 0 RPM
              as a real reading?
            - Output format: lines `FAN<n>|rpm|max_rpm`. Newline handling, locale
              decimal separator, integer vs float printing.
            - Python parser: malformed-line behavior, division-by-zero on
              `max_rpm`, percent computation correctness.
            - Resource cost: does the helper open SMC once per invocation, or
              persist? It is invoked every refresh. Estimate the wakeup cost.
        """),
    },
    {
        "subject": "swift-temp-helper",
        "scope": textwrap.dedent("""\
            Audit `silitop-temps.swift` (92 lines) in full. This is the IOHID-
            based temperature sensor reader.

            File: `/Users/andrewlee/Desktop/Code/silitop/silitop-temps.swift`.
        """),
        "out_of_scope": textwrap.dedent("""\
            - The Python caller that consumes its output (temp-classification).
            - The fan helper (fan-reader).
        """),
        "dimensions": textwrap.dedent("""\
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
        """),
    },
    {
        "subject": "ram-metrics",
        "scope": textwrap.dedent("""\
            Audit `get_ram_metrics` and any helpers it uses.

            Files and ranges:
            - `silitop` lines 397-480 (`get_ram_metrics`). Read the surrounding
              callers (in `main`) to understand how the result is consumed, but
              do not audit the curses render here.
        """),
        "out_of_scope": textwrap.dedent("""\
            - Curses rendering of the memory bar.
            - Total-memory detection via `hw.memsize` IF it overlaps soc-detection;
              just note overlap and continue.
        """),
        "dimensions": textwrap.dedent("""\
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
        """),
    },
    {
        "subject": "curses-primitives",
        "scope": textwrap.dedent("""\
            Audit silitop's curses drawing primitives.

            Files and ranges:
            - `silitop` lines 481-721 covering `init_colors`, `hbar`, `clamp_pct`,
              `compute_bar_layout`, `temp_color`, `draw_box`, `safe_addstr`,
              `draw_core_row`, `draw_fan_row`, `draw_hbar_full`, `draw_spark`.
            - `tests/test_layout.py` to see which of these are unit-tested and
              with what assertions.
        """),
        "out_of_scope": textwrap.dedent("""\
            - The main render loop (main-loop-lifecycle).
            - Color choice / scheme aesthetics.
        """),
        "dimensions": textwrap.dedent("""\
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
        """),
    },
    {
        "subject": "main-loop-lifecycle",
        "scope": textwrap.dedent("""\
            Audit the main render loop, signal/lifecycle handling, and entry
            point.

            Files and ranges:
            - `silitop` lines 722-1208 covering `main` and `entry`.
        """),
        "out_of_scope": textwrap.dedent("""\
            - Individual draw primitives (curses-primitives).
            - Powermetrics parsing internals (powermetrics-parsing); you DO own
              "is the powermetrics subprocess killed cleanly on quit".
            - Install script (install-script).
        """),
        "dimensions": textwrap.dedent("""\
            - `entry()`: sudo check, argparse handling, locale setup for curses
              (LC_ALL/LANG), `curses.wrapper` use, what happens if not run as
              root.
            - Main loop cadence: how often does it call `read_hid_temps`,
              `read_fan_speeds`, `get_ram_metrics`, and the powermetrics reader?
              If a slow helper blocks, does the UI freeze?
            - Resize handling: KEY_RESIZE path, window recreation, redraw races.
            - Quit handling: 'q'/Esc path, SIGINT path, SIGTERM path. Is the
              `powermetrics` subprocess terminated and reaped? Are
              `/tmp/silitop_pm*` files removed?
            - Multiple-instance safety: two silitops running simultaneously will
              both write to `/tmp/silitop_pm*` with the same prefix. Walk through
              what happens.
            - Hot-path allocations: are deques pre-allocated, or recreated each
              frame? Are formatted strings rebuilt every frame even when the
              underlying value is unchanged?
            - Sparkline deque sizing: does it match the actual sparkline width?
              On resize, is the deque truncated, padded, or rebuilt?
            - Color pair lifecycle: are pairs initialized once on entry or
              repeatedly?
            - Exception swallowing: are exceptions in helpers (e.g. powermetrics
              dies, helper binary missing) caught and surfaced, or silently
              eaten?
            - CPU cost of the loop on idle.
        """),
    },
    {
        "subject": "install-script",
        "scope": textwrap.dedent("""\
            Audit `install.sh` (64 lines) and how it interacts with the runtime.

            File: `/Users/andrewlee/Desktop/Code/silitop/install.sh`.
        """),
        "out_of_scope": textwrap.dedent("""\
            - Runtime behavior of the installed binaries.
            - Code signing / notarization unless the script touches it.
        """),
        "dimensions": textwrap.dedent("""\
            - Sudo semantics: README shows `bash install.sh` (no sudo). Does the
              script call sudo internally? Are Swift compilation and `cp` mixed
              into the same sudo elevation? Compiling as root is harmful (creates
              root-owned objects in the repo).
            - Target path: `/usr/local/bin` is the FAR target on Intel macOS; on
              Apple Silicon, Homebrew uses `/opt/homebrew/bin`. `/usr/local/bin`
              still exists and is on PATH for sudo, but should the script prefer
              `/opt/homebrew/bin` if present, or be configurable?
            - Idempotency: rerunning the script. Does it clobber binaries
              cleanly? Does it remove a stale `silitop-fans` if the file is now
              named differently?
            - Swift compile flags: `swiftc -O` vs default? Sandbox? Hardening?
              SDK pinning?
            - Error handling: `set -e`? Aborts on compile failure, or proceeds
              with partial install?
            - Permissions of installed files: 755? 644? Is the Python script
              executable?
            - Uninstall path: is there one?
            - Cross-arch: does anything break on Intel?
            - Version mismatch: what if the user has an older `silitop` already
              installed and only updates one of the binaries?
        """),
    },
    {
        "subject": "interface-contracts",
        "scope": textwrap.dedent("""\
            Audit the cross-language and cross-process contracts that hold the
            three binaries together.

            Files and ranges:
            - The Python parsing code in `silitop` for `silitop-temps` and
              `silitop-fans` output.
            - The Swift print statements in `silitop-temps.swift` and
              `silitop-fans.swift`.
            - The powermetrics plist key contract assumed by `parse_powermetrics`
              and the `extract_*` functions.
        """),
        "out_of_scope": textwrap.dedent("""\
            - Internal correctness of each parser (other agents own that).
            - Sudo / privilege model (safety-security).
        """),
        "dimensions": textwrap.dedent("""\
            - Swift -> Python format `sensor_name|temp`: what if a sensor name
              contains `|`? What if it contains a newline? What if the locale
              prints the float with a comma decimal separator?
            - Swift -> Python format `FAN<n>|rpm|max_rpm`: same questions.
            - Versioning: there is no protocol-version line. If the Swift helper
              changes its output (e.g. adds a column), Python will silently
              misparse. Is this a real risk now, or only future?
            - Plist schema: which `powermetrics` keys does the Python code rely
              on? List them all. macOS minor releases sometimes rename keys.
              Note any key that would be a single-point-of-failure.
            - Exit code contract: do the Swift helpers exit 0 on partial
              success? Does Python check exit codes at all? What if a helper
              returns 1 but printed valid lines?
            - Encoding: Swift defaults to UTF-8 stdout; Python `subprocess`
              decoding mode in this codebase. Match or mismatch?
            - Stderr discipline: anything printed to stderr that should be
              checked?
            - Lifecycle: every tick spawns the helpers as fresh processes. Is
              that wired uniformly, or does one helper persist?
            - Failure modes when a helper binary is missing: graceful degrade,
              loud crash, or quiet zero readings?
        """),
    },
    {
        "subject": "safety-security",
        "scope": textwrap.dedent("""\
            Audit safety and security of the whole pipeline.

            Files and ranges (read these specifically):
            - Every `subprocess.*` call site in `silitop`.
            - Every `open(...)` and `os.path.*` call site involving `/tmp/`.
            - `install.sh` for sudo/path/permission issues that overlap with
              install-script; cite that agent if so.
            - The Swift helpers for any IPC or filesystem access.
        """),
        "out_of_scope": textwrap.dedent("""\
            - Logical correctness of parsers (other agents).
            - Code style.
        """),
        "dimensions": textwrap.dedent("""\
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
        """),
    },
    {
        "subject": "tests-coverage",
        "scope": textwrap.dedent("""\
            Audit `tests/test_layout.py` (311 lines). Assess what is and is not
            tested in the codebase, and the quality of the existing assertions.

            File: `/Users/andrewlee/Desktop/Code/silitop/tests/test_layout.py`.
        """),
        "out_of_scope": textwrap.dedent("""\
            - Bugs in the production code (other agents).
        """),
        "dimensions": textwrap.dedent("""\
            - Inventory: list every function under test and the property each
              test asserts. Note tests that only assert "no exception".
            - Risky logic that is untested: list specifically.
              Candidates to check: powermetrics plist parser, vm_stat parser,
              sysctl SoC detection, Swift output parsers, `_find_helper`
              search order, sparkline deque sizing on resize, `clamp_pct`
              edge cases, `temp_color` thresholds, `_is_efficiency` mapping.
            - Are there any integration tests that spawn the real helpers or
              feed a recorded plist sample? If not, note the gap.
            - Mocking: how does the suite isolate from the platform? Is the
              mocking pinning real behavior or just "no crash"?
            - Determinism: any tests that depend on system time, locale,
              terminal width? If so, list.
            - Speed: total runtime; any tests that block on subprocess?
            - CI config: does the repo have GitHub Actions or similar? (Glance
              at .github/ if present.)
            - Recommend the SMALLEST set of new tests that would catch the
              highest-risk regressions. Rank by ROI.
        """),
    },
]

# Sanity check
assert len(SUBJECTS) == 12, f"Expected 12 subjects, got {len(SUBJECTS)}"
slugs = [s["subject"] for s in SUBJECTS]
assert len(set(slugs)) == 12, "Duplicate slug"

for spec in SUBJECTS:
    body = COMMON_HEADER.format(**spec)
    prompt_path = PROMPTS_DIR / f"{spec['subject']}.md"
    prompt_path.write_text(body)
    run_dir = RUNS_BASE / f"codex_silitop_{spec['subject']}"
    run_dir.mkdir(parents=True, exist_ok=True)
    # Clear prior status if rerunning
    for stale in ("status", "output.md", "events.jsonl", "stderr.log",
                  "watchdog.log", "session.txt", "pid"):
        p = run_dir / stale
        if p.exists():
            p.unlink()
    shutil.copy(prompt_path, run_dir / "prompt.txt")
    print(f"staged: {spec['subject']:24s}  prompt={prompt_path}  run_dir={run_dir}")

print(f"\n{len(SUBJECTS)} prompts staged. Next: fire {len(SUBJECTS)} background codex agents.")
