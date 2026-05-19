# silitop audit — Opus follow-up synthesis

This synthesis assumes the twelve narrow codex passes are correct on the facts they cite. I read all four source files (`silitop`, `silitop-temps.swift`, `silitop-fans.swift`, `install.sh`) and `tests/test_layout.py` end-to-end. Where I disagree with a codex severity I say so explicitly. Where I could not verify on hardware I label the assumption.

## 1. Cross-cutting themes

### Theme 1: fail-open to zero (confirmed; this dominates)

Every data-collection path in silitop is written so that absent, malformed, timed-out, or crashed inputs produce a numeric zero (or `0%`, or empty list) that flows directly into the UI without any "unavailable" sentinel. The orchestrator-level guess is correct. The pattern shows up in at least nine of the twelve subsystem reports:

- `powermetrics-parsing:CRIT-2` (missing sampler keys -> 0 watts/0% activity)
- `ram-metrics:CRIT-1` (vm_stat failure -> 0 GB / 0%)
- `temp-classification:HIGH-1` (helper failure -> {} -> hidden pane)
- `fan-reader:CRIT-1` (failed `F0Ac` read -> 0 RPM rendered as "off")
- `fan-reader:HIGH-2` (first empty helper result -> fans permanently disabled)
- `swift-temp-helper:HIGH-1` (all client types fail -> exit 0, silent)
- `main-loop-lifecycle:CRIT-1` (powermetrics dies -> last frame frozen on screen)
- `interface-contracts:HIGH-1` and `HIGH-2` (entire schema drift -> trusted zeros)
- `tests-coverage:CRIT-1` (test explicitly blesses zero-on-failure as correct)

The shared mechanism is bare-default reads (`d.get(key, 0)`, `try/except Exception: return {}`, `idle_ratio` default `1` so active becomes `0`) layered on top of broad `except Exception` swallows. The fix is structural, not site-by-site: every collector should distinguish "did not measure" from "measured zero." Right now nothing in the data layer can carry that signal upward.

A second-order consequence I noticed while tracing: because the user sees a number that looks live, no human-in-the-loop will catch the degradation. The combination of fail-open-to-zero and no-stale-data-check (theme 2) means silitop can show garbage for an arbitrarily long time without the dashboard looking wrong.

### Theme 2: no liveness or freshness signal

The main loop trusts the data source by construction. There is no `pm_proc.poll()`, no file-mtime check, no monotonic "last successful sample" timestamp, no helper-failure counter, no schema-version probe. The whole UI assumes data is fresh just because the dict-fetches succeeded. Supporting findings: `main-loop-lifecycle:CRIT-1` (no poll/mtime check, stale frame stays onscreen), `powermetrics-parsing:HIGH-1` (powermetrics startup failure indistinguishable from "data not ready yet"), `interface-contracts:HIGH-2` (helper failure indistinguishable from no sensors), `temp-classification:HIGH-1` (transient timeout = pane vanishes).

### Theme 3: helper boundary is unprotected protocol

The Python <-> Swift handoff uses pipe-delimited stdout with no version header, no escape rules, no schema check, no exit-code semantics. `safety-security:CRIT-2` (installed helpers writable by non-root), `interface-contracts:MED-1` and `MED-2` (no protocol version, locale-sensitive number formatting), `fan-reader:HIGH-2` (Swift exits 0 for "broken AppleSMC" and for "no fans"), `swift-temp-helper:HIGH-1` (Swift exits 0 on total failure). The boundary collapses any kind of "broken" into "nothing to say."

## 2. Seams: bugs that span agent scopes

### SEAM-1: powermetrics death + glob-cleanup + no SIGTERM = stale-frame-then-corpse
- **Location:** `silitop:131-133` (startup glob), `silitop:737-738` (timecode path), `silitop:776-794` (no poll), `silitop:1163-1172` (cleanup), no SIGTERM handler anywhere.
- **Combined mechanism:** (1) `main-loop-lifecycle:CRIT-1` already shows that if `powermetrics` dies after the first sample, the curses dashboard keeps re-rendering the same last-parsed values. (2) `main-loop-lifecycle:HIGH-2` shows that a second silitop instance globs `/tmp/silitop_pm*` on startup and deletes the first instance's live plist file. (3) `main-loop-lifecycle:HIGH-1` shows that SIGTERM to the Python parent bypasses the `finally` block, so the privileged `powermetrics` child survives and so do the `/tmp/silitop_pm*` files. (4) `safety-security:CRIT-1` shows that the `/tmp` path is predictable (`int(time.time())`), globally readable/writable, and pre-cleanup of the prefix runs as root with no `OSError` guard. Combine them: a user runs `sudo silitop` in tmux, the curses front-end is SIGTERM'd by some other process (a session manager, a watchdog, sudo timeout), Python exits without `finally`, `powermetrics` keeps running as root writing the plist, the `/tmp` file is now orphaned with no owning Python. The user starts a new `sudo silitop`. Startup runs `glob("/tmp/silitop_pm*")` and deletes the orphan plist while the orphaned root `powermetrics` is still writing it. The new `powermetrics` child opens its own predictable path. If a local attacker now pre-creates `/tmp/silitop_pm<predicted-timestamp>` between cleanup (`silitop:131-132`) and `powermetrics` open (`silitop:147-148`), they win the race and steer a root file write.
- **Net impact:** A SIGTERM in any reasonable production setup (launchd, tmux kill-session, sudo timeout) creates an orphaned root `powermetrics`. The next normal startup compounds it with prefix-globbing the orphan. The combination converts a benign clean-shutdown bug into something that leaves attacker-influenceable state across restarts. Independent of the security framing, just two normal user runs in the same second (clean exit then immediate restart) can step on each other through the shared prefix.
- **Fix sketch:** Three changes collapse all of it: (a) `tempfile.mkstemp(prefix="silitop_pm_", dir="/tmp")` with `O_EXCL|O_NOFOLLOW`, store the fd, never glob-delete the prefix; (b) install a SIGTERM handler that sets a flag the main loop reads; (c) before accepting `parsed is None`, call `pm_proc.poll()` and break to cleanup if it has exited.

### SEAM-2: fail-open-to-zero + no liveness check = "Total: 7.5W" on a 100-watt MacBook
- **Location:** `silitop:247` (package_w divided by 1000), `silitop:830` (then divided by interval), `silitop:776-789` (no `pm_proc.poll()`), `silitop:798-810` (extract path uses .get(..., 0)).
- **Combined mechanism:** This is `powermetrics-parsing:CRIT-1` (interval double-divides package power) + `powermetrics-parsing:CRIT-2` (missing keys become 0) + `main-loop-lifecycle:CRIT-1` (no liveness check). Alone, CRIT-1 only manifests when `--interval` is greater than 1. CRIT-2 alone produces a fully zero dashboard which a user might notice. The freshness gap alone means stale-but-plausible numbers persist. The combination: when `--interval 2` is used after a `combined_power` key change in a future macOS, the user sees CPU + GPU sum to a real load number, while `Total` reads less than the visible components. Because the freshness check is missing, even if `powermetrics` has actually died and `combined_power` is just the last value cached in the tail of the file, the screen still says `Total: 7.5W` looks like a stale reading rather than a parser bug, and so a maintainer chasing the wrong root cause may patch `combined_power` divisions without finding CRIT-1.
- **Net impact:** Two independently latent bugs masquerade as one impossible reading and slow diagnosis.
- **Fix sketch:** Fix CRIT-1 (remove the `/interval_s` at line 830) and add a `combined_power` presence check. Then any future schema drift surfaces as "Total: unavailable" instead of an arithmetic puzzle.

### SEAM-3: fan_available latch + first-poll helper bug = permanently-no-fans on a transient SMC blip
- **Location:** `silitop:760-762` (latch state), `silitop:816-821` (latch transition), `silitop-fans.swift:107-113` (`exit(0)` on AppleSMC open failure).
- **Combined mechanism:** `fan-reader:HIGH-2` shows the Python side: `fan_available=True` initially, `fan_seen=False`. First successful read clears the latch into "we have fans." First empty read while `fan_seen` is still false sets `fan_available=False` permanently. `fan-reader:HIGH-3` and `fan-reader:CRIT-1` show the Swift side: AppleSMC open failure, `FNum` read failure, and confirmed-fanless all return empty stdout with `exit(0)`. So a transient AppleSMC contention or an in-flight kext load at exactly the first poll (slow_poll_counter==0, which fires within the first three seconds of startup) is indistinguishable from a fanless MacBook Air. The decision is made permanent within seconds and is never revisited. Combine with `interface-contracts:HIGH-2` (helper failure swallowed in Python) and the user has no way to tell why fans are missing.
- **Net impact:** Cold-start race conditions silently demote a fan-equipped MacBook Pro into a fan-blind monitor for the rest of the session.
- **Fix sketch:** One change in Swift fixes the whole chain: differentiate "confirmed fanless" (exit 0, empty stdout, `FNum == 0`) from "broken" (nonzero exit, stderr message). Python then only sets `fan_available=False` on the confirmed-fanless contract.

### SEAM-4: helper resolution order + writable install dir = root code-execution surface
- **Location:** `install.sh:40-46` (no chown root:wheel), `silitop:299-310` (`_find_helper` checks repo-local first), `silitop:319, 339` (subprocess executes whatever `_find_helper` returns).
- **Combined mechanism:** `safety-security:CRIT-2` notes that `/usr/local/bin` on this host is `andrewlee:admin` and group-writable, and the installer never enforces root ownership. `install-script:HIGH-1` adds that the installer "verifies" success via `command -v silitop`, which trusts PATH; an older `/opt/homebrew/bin/silitop` shadows the new install. `_find_helper` (silitop:302-309) tries the directory next to the Python frontend first, then `/usr/local/bin`. So an unprivileged user who can write `/opt/homebrew/bin` (the homebrew default permissions on Apple Silicon are user-owned) can drop a malicious `silitop` and `silitop-temps` next to it. The installer reports success against that shadow path. The next `sudo silitop` then runs both the shadow front-end as root and the shadow helpers as root, because `_find_helper` prefers the script-relative path.
- **Net impact:** A non-root user with normal homebrew permissions can stage a root-execution payload by exploiting the installer's PATH-versus-INSTALL_DIR mismatch.
- **Fix sketch:** Two changes collapse it. (a) In `install.sh`, switch to `install -o root -g wheel -m 0755`, then assert `command -v silitop` resolves to `${INSTALL_DIR}/silitop` and fail otherwise. (b) In `_find_helper`, prefer `/usr/local/bin/silitop-{temps,fans}` over the script-relative path when `os.geteuid() == 0`, and refuse to execute helpers whose owner is not root.

### SEAM-5: powermetrics interval contract is set in one place, divided in another, never verified
- **Location:** `silitop:738` (passes `args.interval * 1000` to `run_powermetrics`), `silitop:826-830` (divides energy by `args.interval`), `silitop:1159` (sleeps for `args.interval * 0.8`).
- **Combined mechanism:** The `-i` flag passed to powermetrics is `args.interval * 1000` milliseconds. The Python loop divides energy fields by `args.interval` seconds to convert mJ-per-sample into watts. The implicit assumption is that exactly one new sample is produced per `args.interval` seconds and that the Python loop reads exactly one. But the loop's `last_timestamp` dedupe means slow rendering (helper hang, terminal slow scroll, RAM `vm_stat` blocking) can cause Python to read every Nth sample, in which case `cpu_energy` represents N intervals of accumulated energy but is still divided by `args.interval`, giving 1/N the true wattage. `powermetrics-parsing:CRIT-1` is the symmetric mirror: `combined_power` is already a power value but is still divided by interval, giving 1/interval the true wattage. Both result from the same underlying issue: no contract enforcing that "one Python iteration consumes exactly one powermetrics sample of length `args.interval`."
- **Net impact:** Either dropped frames (Python falls behind) or fast frames (Python re-renders identical samples without recognizing they are the same energy bucket) corrupt wattage readings.
- **Fix sketch:** Track the last consumed plist `timestamp` and compute energy-per-second as `delta_energy / delta_timestamp` instead of `energy / args.interval`. For `combined_power`, do not divide. The two cleanups eliminate both the documented CRIT-1 and the latent drift.

### SEAM-6: contract drift between SoC labels and the cluster-name first-character trick
- **Location:** `silitop:79-80` (sets `fast_prefix = fast_type[0]`), `silitop:199-200` (`_is_efficiency`), `silitop:880-881` (uses prefixes for labels).
- **Combined mechanism:** `soc-detection:HIGH-1` flagged the case-sensitivity bug for M1-M4. The broader contract problem is that `_is_efficiency` is a single-character substring match between two sources (`system_profiler` and `powermetrics` cluster names) that are guaranteed-different vocabularies. On M5, `system_profiler` says "Super and Performance" and `powermetrics` cluster names start with `S` and `P` (verified in `soc-detection:Verified` section). The first character matches by coincidence: Super -> S -> matches S-Cluster; Performance -> P -> matches P-Cluster. On M1-M4, `system_profiler` says "performance and efficiency"; `powermetrics` cluster names on those chips reportedly begin with `E` and `P`. The lowercase `e` from `system_profiler` does not match the uppercase `E` from `powermetrics`. The whole P/E classification depends on a string-prefix coincidence that is not a contract.
- **Net impact:** Per-tier bucketing fails on the platform variants the README explicitly says need testing (M1-M4).
- **Fix sketch:** Drop the first-character indirection. Detect tier directly from powermetrics cluster names (E-Cluster, P-Cluster, S-Cluster) and only use `system_profiler` for the display label, not for bucketing. This collapses the contract.

## 3. New findings the codex pass missed

### NEW-CRIT-1: `args.interval == 1` is silently assumed throughout the UI, including history sizing and slow-poll cadence
- **Location:** `silitop:747-748` (`max_history = 120`), `silitop:764` (`slow_poll_counter` mod 3), `silitop:1159` (`time.sleep(args.interval * 0.8)`), `silitop:750` (`avg_window = int(args.avg / args.interval)`).
- **Mechanism:** The README documents `--interval` defaults to 1 second and is settable. The code has hard-coded constants tuned for that default. (a) Power and network/disk sparklines have `maxlen=120`. With `--interval 5`, that is 600 seconds of history rather than 120, even though the user said sample every 5 seconds. (b) The slow-poll counter polls helpers every 3 ticks, which is 3 seconds at default but 15 seconds at `--interval 5`. So temperature staleness scales linearly with `--interval`. (c) The `time.sleep(args.interval * 0.8)` at the end of the loop assumes 80% sleep + 20% work, which only holds for the chosen default. With `--interval 0` it sleeps 0 seconds and busy-loops. With `--interval 0` we also hit the division-by-zero at `silitop:826-830` (already in `main-loop-lifecycle:HIGH-3`).
- **Impact:** Power averaging window (`--avg 30` divided by `args.interval`) at `args.interval=5` yields `avg_window=6`, only six samples averaged; the displayed "CPU avg" stops being a meaningful 30-second average.
- **Repro:** `sudo silitop --interval 5 --avg 30`; observe `avg_window` is six samples, network history is 600 seconds of data, helper polls only every 15 seconds.
- **Fix sketch:** Normalize all rate-based windowing on wallclock seconds, not iteration count. `slow_poll_counter` should track elapsed time and trigger on `>= 3.0s`. `max_history` should be `120 / args.interval` rounded up. Validate `--interval >= 1`.
- **Why no codex agent caught it:** The interval is mentioned in `main-loop-lifecycle:HIGH-3` only for negative/zero values, in `powermetrics-parsing:CRIT-1` only for the power-units math, and in `curses-primitives:LOW-1` only as "narrow terminals leave unused history." None traced the full effect of `--interval N` across all four time-scaled subsystems. This is the canonical "spans scopes" bug.

### NEW-CRIT-2: `cpu_die_max` and `gpu_die_max` are gated by truthiness, so a measured temperature of exactly 0.0C disappears from the title bar
- **Location:** `silitop:886-887`, `silitop:942-944`.
- **Mechanism:** The code reads `cpu_die_max = max(cpu_die_vals) if cpu_die_vals else None`, then `cpu_temp_str = f"  {cpu_die_max:.0f}°C" if cpu_die_max else ""`. Same pattern on lines 942-944 for GPU. Python's truthiness rule treats `0.0` as falsy. If any sensor genuinely reads zero (e.g. cold-boot before thermistors stabilize, or a calibration sensor that reports zero, or a hardware fault) the maximum across cpu_die_vals can be 0.0 (impossible if there are any positive readings, but possible if all sensors read 0). Then the `:.0f` formatting is skipped and the title bar drops the temperature.
- **Impact:** Lower-severity than NEW-CRIT-1 because Apple Silicon thermistors do not legitimately report 0. But the same idiom can drop a `gpu_die_max` of exactly zero, and the code at line 1098 (`max {cpu_die_max:.0f}°C`) is gated by `cpu_die_vals`, not by `cpu_die_max`. So the Temperatures box would happily print `CPU Die: 0°C (max 0°C)` while the title bar prints no temperature at all. The inconsistency between two display sites breaks the rule that "what the title shows and what the body shows agree." It is a CRIT under the project's severity definition ("incorrect readings the user trusts") in the limit case.
- **Repro:** Force `hid_temps = {"PMU tdie0": 0.0, "PMU tdie1": 0.0, "PMU tdie2": 0.0, "PMU tdie3": 0.0}` (any nonempty all-zero dict) and step through the title-building code.
- **Fix sketch:** Use `is not None` rather than truthiness: `cpu_temp_str = f"  {cpu_die_max:.0f}°C" if cpu_die_max is not None else ""`. Same at line 944.
- **Why no codex agent caught it:** `temp-classification` looked at sensor classification logic; `curses-primitives` looked at draw primitives; neither traced the title-bar string construction. This is a whole-file-only bug.

### NEW-HIGH-1: `pm_proc` start failure raises before `try/finally`, leaking sampler attempts as zombies
- **Location:** `silitop:738` (start), `silitop:139-167` (`run_powermetrics`), `silitop:770` (try-block start).
- **Mechanism:** `run_powermetrics` starts a `Popen`, waits 1.5 seconds; if it exits, retries with the fallback sampler set, then if that also fails starts a third process unconditionally (line 158-166) and returns it without checking. If `Popen` itself raises (e.g. `powermetrics` binary not found in PATH, or sudo timeout, or fork failure under memory pressure), the exception propagates upward through `run_powermetrics`, then through the assignment at silitop:738. That happens before the `try:` block at silitop:770. The `finally` cleanup at silitop:1163-1172 then runs against an uninitialized `pm_proc`, which is `NameError`, or against `None` if the call returns None on some path. Worse, between the two loop attempts at lines 139-156, if the first attempt has actually started a `Popen`, the failed-sampler retry sequence does not `terminate()` the spawned process; it just falls out of the `try` block, returning to the `for samplers in samplers_options:` head. If the process exited cleanly (exit_code != 0) within 1.5s, that is fine. If it is still alive at 1.5s, that is "success" and the function returns. But if it exited but with a residual subprocess.Popen object whose `.wait()` returned, then a second iteration of the loop starts a second `Popen`, and the first one is unreferenced but already-reaped.
- **Impact:** Process startup failures bypass cleanup. Multiple sampler attempts spawn multiple `Popen`s without explicit termination of failed predecessors. Under heavy resource pressure, this can fork-bomb mildly.
- **Repro:** Inject a permission failure or PATH miss for `powermetrics`, then observe `entry()` traceback skips cleanup.
- **Fix sketch:** Move `try:` to immediately after `pm_proc = run_powermetrics(...)` (also addresses `main-loop-lifecycle:HIGH-3`). In `run_powermetrics`, explicitly `proc.terminate()` and `proc.wait()` on the sampler retry path before continuing.
- **Why no codex agent caught it:** `main-loop-lifecycle:HIGH-3` flagged the argparse-validation aspect of the same bug but did not trace the `Popen` retry leak inside `run_powermetrics` itself. `powermetrics-parsing:HIGH-1` flagged the "infinite waiting screen" symptom but did not look at process lifecycle.

### NEW-HIGH-2: The fan-box-versus-CPU-box layout uses `e_box_w` (left column) for the FAST tier and `p_box_w` (right column) for the SLOW tier, contradicting the variable names
- **Location:** `silitop:873-874` (`e_box_w` and `p_box_w` defined), `silitop:884` (comment claims slow cores get longer column but code does opposite), `silitop:901, 922` (left box uses `e_box_w`), `silitop:925` (right box uses `p_box_w`), `silitop:927-935` (p_cores drawn in left, e_cores drawn in right).
- **Mechanism:** Quote: `e_box_w = half_w - 1; p_box_w = max_w - half_w - 1`. The names suggest "e cores get e_box_w." In fact the LEFT column at offset 0 gets `e_box_w` and renders the FAST tier (variable `p_cores`, which holds the fast tier per silitop:75 comment). The RIGHT column at offset `half_w` gets `p_box_w` and renders the SLOW tier (variable `e_cores`, holding the slow tier per silitop:76 comment). The widths happen to be approximately equal (off by 1) so the visual difference is invisible. But the comment at silitop:884 says "Slow cores on the right (more cores)" which is what the code does, except the variable named `p_box_w` (which a reader would assume is the "performance" / fast width) is actually the slow-side width.
- **Impact:** Future code review or width adjustment that adds asymmetric padding will silently flip which tier is wider. Existing tests don't catch it because they don't render this section.
- **Repro:** Code inspection only; no runtime symptom.
- **Fix sketch:** Rename `e_box_w` to `left_box_w` and `p_box_w` to `right_box_w`, since the column they describe has no inherent E or P meaning.
- **Why no codex agent caught it:** This is a whole-file readability issue; none of the twelve scopes covered the CPU section layout names specifically. `soc-detection` covered tier naming but not column-width naming.

### NEW-MED-1: `process_cpu_freq` fallback uses cluster frequency, but the cluster frequency itself is harvested with no idle-check, so a fully-idle cluster may also report `freq_hz=0`
- **Location:** `silitop:215-226`.
- **Mechanism:** Quote: `cluster_freq_hz = cluster.get("freq_hz", 0); ... if core_freq_hz > 0: freq = ...; elif cluster_freq_hz > 0: freq = ...; else: freq = 0`. The comment claims "powermetrics reports freq_hz=0 for cores at 100% utilization." That is asymmetric: it can also be zero when cores are fully idle. The `freq_cache` at silitop:756 stabilizes individual cores but is per-core. If all cores AND the cluster all hit `freq_hz=0` at once (idle plus a momentary sampling gap), the cache may have a previous value for cores but nothing for the cluster, and `freq` collapses to 0 with no further fallback.
- **Impact:** Per-core frequencies can be displayed as "0 MHz" on a freshly-loaded sample when no cache exists yet, then flicker after the first non-zero sample populates the cache.
- **Repro:** Start `sudo silitop` and observe the first 1-2 frames before `freq_cache` is populated; cores may briefly show 0 MHz.
- **Fix sketch:** Cache the cluster frequency too, and prefer it as the second fallback before zero. Or render frequency as `--` rather than `0` when unavailable.
- **Why no codex agent caught it:** `powermetrics-parsing` covered the schema-drift case, not the legitimate `freq_hz=0` semantics. `soc-detection` covered tier identification, not frequency interpretation.

### NEW-MED-2: `color_pair` 0 is used in `temp_color` for `temp < 0`, but `init_colors` never initializes pair 0
- **Location:** `silitop:531-534`, `silitop:481-491`.
- **Mechanism:** `temp_color` returns `2` for negative temperatures (`if temp < 0: return 2`). The comment at 534 says "color pair 2" is the white text color. That part is fine. But `init_colors` only initializes pairs 1-7. Curses pair 0 is reserved for default-on-default. If any code path slips and uses pair 0, it falls back to default colors silently, but pair 2 is initialized at line 486 (white on default). So this finding is partially-bug, partially OK. The real issue is that `temp_color` was clearly meant to return a "sentinel for invalid" color, but it returns pair 2 (the same as the default text color), which makes negative temperatures indistinguishable from valid ones in the UI. There is no path that displays a negative temperature reaching this branch (temperatures are filtered to `temp > 0` in the Swift helper), but if anyone adds a negative-temperature path the user gets no visual cue.
- **Impact:** Latent. No current data source produces negative temperatures.
- **Repro:** Modify Swift helper to emit negative values; UI displays them in default white text instead of a warning color.
- **Fix sketch:** Return pair 3 (yellow/warning) for negative temperatures, or add an explicit "unknown" pair.
- **Why no codex agent caught it:** `curses-primitives` flagged the 70C boundary mismatch but not the negative path. `temp-classification` did not trace the color-mapping callee.

### NEW-LOW-1: `BLOCK_CHARS` is dead code (also called out in `curses-primitives:LOW-1`, but worth reinforcing alongside the next finding)
- **Location:** `silitop:23`.
- **Mechanism:** The constant `BLOCK_CHARS = " ▏▎▍▌▋▊▉█"` is the canonical eight-step partial-cell sequence for sub-character bar resolution. Nothing in the file references it. `hbar` uses `█` and `░` directly; `draw_core_row`/`draw_fan_row`/`draw_hbar_full` all use those same literals.
- **Impact:** The constant occupies a line and suggests sub-cell rendering is implemented when it is not.
- **Fix sketch:** Delete it, or use it in `hbar` to add a single partial-block character at the boundary.
- **Why noted separately:** The codex pass flagged the related dead function `hbar` but the dead constant is a separate symptom of the same design intent left unfinished.

## 4. Master ranked list (deduped)

I treat the codex severities as starting points and adjust where my whole-codebase trace changed my view. Where I demote a finding I say so. I merge overlapping reports into one row.

### CRIT
1. **[CRIT]** Stale `powermetrics` keeps the dashboard rendering frozen, old values onscreen `(merges: main-loop-lifecycle:CRIT-1)` — `silitop:776-794`; no `pm_proc.poll()` or file-mtime check.
2. **[CRIT]** RAM subprocess failure silently degrades to `Memory: 0/64 GB (0%)` `(merges: ram-metrics:CRIT-1 + main-loop-lifecycle:CRIT-2 + tests-coverage:CRIT-1)` — `silitop:407-465, 1010-1015`; tests explicitly pin this bad behavior.
3. **[CRIT]** Package wattage is divided by `args.interval` twice `(merges: powermetrics-parsing:CRIT-1)` — `silitop:247, 830`; `Total` watts wrong on any non-default interval.
4. **[CRIT]** Missing powermetrics sampler keys become trusted zeros `(merges: powermetrics-parsing:CRIT-2 + interface-contracts:HIGH-1)` — `silitop:205-285`; affects CPU, GPU, network, disk, ANE.
5. **[CRIT]** Failed SMC current-RPM reads are reported as 0 RPM and shown as "fan off" `(merges: fan-reader:CRIT-1)` — `silitop-fans.swift:119-124`, `silitop:913`.
6. **[CRIT]** Root `/tmp/silitop_pm*` path is predictable, glob-deleted as root, not exclusively created `(merges: safety-security:CRIT-1 + main-loop-lifecycle:HIGH-2)` — `silitop:131-133, 737, 1169-1172`; symlink/directory race plus cross-instance unlink.
7. **[CRIT]** Installed helpers can be writable by non-root and are then executed by `sudo silitop` `(merges: safety-security:CRIT-2 + install-script:HIGH-1)` — `install.sh:40-46`, `silitop:299-310, 319, 339`.
8. **[CRIT]** All-time-scaled subsystems silently assume `args.interval == 1`; `--interval 5` produces wrong avg windows, wrong helper poll cadence, and wrong sparkline coverage `(new: this pass — NEW-CRIT-1)` — `silitop:747, 750, 764, 1159`.
9. **[CRIT]** `cpu_die_max` and `gpu_die_max` truthiness check drops a measured 0°C from the title bar while the body still shows it, breaking display consistency `(new: this pass — NEW-CRIT-2)` — `silitop:886-887, 942-944`. I rate this CRIT under the project's definition ("incorrect readings the user trusts"); if Andrew disagrees because the precondition is rare, downgrade to HIGH.

### HIGH
10. **[HIGH]** powermetrics startup failure leaves an infinite "Waiting for powermetrics data..." with no diagnostic `(merges: powermetrics-parsing:HIGH-1)` — `silitop:139-167, 776-789`.
11. **[HIGH]** SIGTERM bypasses cleanup, leaving root `powermetrics` running and `/tmp` files behind `(merges: main-loop-lifecycle:HIGH-1)` — `silitop:1163-1172`, no signal handler.
12. **[HIGH]** Invalid `--avg` or `--interval` values crash before cleanup, leaking the just-started `powermetrics` child `(merges: main-loop-lifecycle:HIGH-3)` — `silitop:738, 750, 770, 1180-1185`.
13. **[HIGH]** Blocking helper calls freeze the UI for up to 6 seconds (3s temps + 3s fans) and ignore `q`/Esc during the block `(merges: main-loop-lifecycle:HIGH-4)` — `silitop:814-818`.
14. **[HIGH]** M1-M4 case-sensitive prefix bug causes efficiency clusters to be classified as performance `(merges: soc-detection:HIGH-1)` — `silitop:79-80, 199-200`.
15. **[HIGH]** SoC name has no `system_profiler` fallback; sandboxed/restricted hosts show "Apple Silicon" and fall to base TDP bucket `(merges: soc-detection:HIGH-2)` — `silitop:49-56, 113-124`.
16. **[HIGH]** Helper failures (temps and fans) become silent empty data `(merges: temp-classification:HIGH-1 + interface-contracts:HIGH-2)` — `silitop:313-353, 813-823`.
17. **[HIGH]** CPU/GPU die split hardcoded to "last 2 PMU tdie zones are GPU" with no validation on M1-M4 `(merges: temp-classification:HIGH-2)` — `silitop:363-390`.
18. **[HIGH]** Swift fan helper uses 32-bit float decoder for all SMC values; `fpe2` keys are reinterpreted as tiny floats that render as zero `(merges: fan-reader:HIGH-1)` — `silitop-fans.swift:23-26, 82-126`.
19. **[HIGH]** First empty fan-helper result permanently disables fan reads for the process lifetime `(merges: fan-reader:HIGH-2)` — `silitop:760-762, 816-821`, `silitop-fans.swift:107-113`.
20. **[HIGH]** Fan helper's `exit(0)` on error paths bypasses `defer { IOServiceClose }` `(merges: fan-reader:HIGH-3)` — `silitop-fans.swift:107-113`.
21. **[HIGH]** Swift temp helper exits 0 with no output for total failure; caller cannot distinguish "no sensors" from "broken" `(merges: swift-temp-helper:HIGH-1)` — `silitop-temps.swift:39-92`.
22. **[HIGH]** Swift temp helper reads undocumented field `0x000F0001` before the documented base field `(merges: swift-temp-helper:HIGH-2)` — `silitop-temps.swift:61-80`.
23. **[HIGH]** Preferred RAM formula treats every `File-backed pages` as cache, contradicting Activity Monitor's accounting `(merges: ram-metrics:HIGH-1)` — `silitop:431-443, 460-463`.
24. **[HIGH]** Installer "verifies" via `command -v silitop` and trusts PATH; an older shadow binary in `/opt/homebrew/bin` is validated as the install target `(merges: install-script:HIGH-1)` — `install.sh:50-54`.
25. **[HIGH]** Root subprocesses are called by basename (sysctl, system_profiler, nice, powermetrics, vm_stat), so a poisoned PATH could swap them `(merges: safety-security:HIGH-1)` — `silitop:1, 50-52, 60-62, 88-95, 101-103, 140-148, 411, 467, 741-742`.
26. **[HIGH]** Tests do not cover powermetrics plist ingestion or extractors; a parser regression passes CI `(merges: tests-coverage:HIGH-1)` — `tests/test_layout.py` lacks any fixture for `parse_powermetrics`/`extract_*`.
27. **[HIGH]** Tests do not cover SoC detection or `_is_efficiency` bucketing for M1-M5 `(merges: tests-coverage:HIGH-2)`.
28. **[HIGH]** `run_powermetrics` retry loop does not terminate failed `Popen`s before retrying, and a `Popen()` raise before `try:` leaks the child `(new: this pass — NEW-HIGH-1)` — `silitop:139-167, 738`.
29. **[HIGH]** Left/right CPU box width variables are named after E/P tiers but actually describe column positions, inverting the apparent semantics; a future asymmetric width change will silently flip tiers `(new: this pass — NEW-HIGH-2)` — `silitop:873-874, 884, 901-935`.

### MED
30. **[MED]** Empty cluster name crashes `_is_efficiency` with `IndexError` `(merges: powermetrics-parsing:MED-1)` — `silitop:199`.
31. **[MED]** Non-finite (`NaN`) and negative numeric plist fields propagate without sanitization and can crash later `int()` conversions `(merges: powermetrics-parsing:MED-2 + curses-primitives:MED-1)` — `silitop:217-224, 503-505`.
32. **[MED]** `get_soc_info()` returns guessed 4+4 Super/Perf as if detected on detection failure `(merges: soc-detection:MED-1)` — `silitop:38-48`.
33. **[MED]** Core-count fallback uses `hw.perflevelN.logicalcpu` (current power-mode availability) instead of `hw.perflevelN.physicalcpu` or `logicalcpumax` `(merges: soc-detection:MED-2)` — `silitop:84-96`.
34. **[MED]** SSD/battery sensor classification only matches two exact M5-style names and silently drops everything else `(merges: temp-classification:MED-1)` — `silitop:356-384`.
35. **[MED]** Temp parser uses `split("|", 1)` and discards malformed lines without a diagnostic counter `(merges: temp-classification:MED-2 + interface-contracts:MED-1)` — `silitop:321-327`.
36. **[MED]** Failed `F<n>Mx` reads default to uncited `6500` RPM, fabricating fan percentages `(merges: fan-reader:MED-1)` — `silitop-fans.swift:120-131`.
37. **[MED]** Python accepts NaN/inf from fan helper and later crashes in percent conversion `(merges: fan-reader:MED-2)` — `silitop:341-348, 908-910`.
38. **[MED]** Swift temp-helper product-name dedupe drops sensors that share `Product` names (e.g. multiple batteries) `(merges: swift-temp-helper:MED-1)` — `silitop-temps.swift:53-59`.
39. **[MED]** Missing individual `vm_stat` fields silently default to zero, corrupting one breakdown bucket while the rest renders healthy `(merges: ram-metrics:MED-1)` — `silitop:431-463`.
40. **[MED]** RAM polling runs `vm_stat` and `sysctl vm.swapusage` per sample with no timeout; a hung shadow command stalls the UI loop `(merges: ram-metrics:MED-2)` — `silitop:411, 467`.
41. **[MED]** Locale is not initialized before curses; under `LC_ALL=C` Unicode boxes/sparklines can silently disappear `(merges: main-loop-lifecycle:MED-1 + curses-primitives:MED-2)` — `silitop:1204`.
42. **[MED]** `KEY_RESIZE` is not handled; resize only takes effect after the next accepted powermetrics sample `(merges: main-loop-lifecycle:MED-2)` — `silitop:772-774, 851-852`.
43. **[MED]** `temp_color(70)` returns red, contradicting the README "yellow 50-70C" `(merges: curses-primitives:MED-3)` — `silitop:531-539`.
44. **[MED]** Tests do not cover boundary values of `clamp_pct`, `temp_color`, helper parsing, or `_find_helper` `(merges: curses-primitives:MED-4 + tests-coverage:MED-1 + tests-coverage:MED-2)` — `tests/test_layout.py`.
45. **[MED]** Swift `sudo bash install.sh` compiles helpers as root, leaving root-owned build artifacts that future non-root rebuilds can't overwrite `(merges: install-script:MED-1)` — `install.sh:35-46`.
46. **[MED]** Sequential `cp` + `chmod` in installer can leave a mixed-version install on partial failure `(merges: install-script:MED-2)` — `install.sh:41-46`.
47. **[MED]** No protocol version on helper output; one extra column drops every row silently `(merges: interface-contracts:MED-2)` — `silitop-{temps,fans}.swift`, `silitop:321-350`.
48. **[MED]** Cluster-level frequency fallback can also be zero with no further fallback for the first 1-2 frames `(new: this pass — NEW-MED-1)` — `silitop:215-226`.
49. **[MED]** `temp_color(-1)` returns a white-on-default pair indistinguishable from normal text instead of a warning color `(new: this pass — NEW-MED-2)` — `silitop:531-534`.

### LOW
50. **[LOW]** `BLOCK_CHARS` and `hbar` are dead, and `hbar` can return more than `width` characters at negative percentages `(merges: curses-primitives:LOW-1 + NEW-LOW-1)` — `silitop:23, 494-500`.
51. **[LOW]** `system_profiler` parser depends on exact English wording; localized output drops to fallback `(merges: soc-detection:LOW-1)` — `silitop:64-71`.
52. **[LOW]** Sparkline history is fixed at 120 samples and not resized with the terminal `(merges: main-loop-lifecycle:LOW-1)` — `silitop:747-768`.
53. **[LOW]** Python does not pin UTF-8 explicitly when decoding helper stdout `(merges: interface-contracts:LOW-1)` — `silitop:319, 339`.
54. **[LOW]** Swift temp helper success exit bypasses ARC release of the IOHID client (process-exit reclaims it; cosmetic) `(merges: swift-temp-helper:LOW-1)` — `silitop-temps.swift:89-90`.
55. **[LOW]** No CI workflow, even for the narrow existing tests `(merges: tests-coverage:LOW-1)`.
56. **[LOW]** Installer has no `--uninstall` and does not reject unknown arguments `(merges: install-script:LOW-1)` — `install.sh:35-64`.

Final unique count: 56 (down from 60 raw codex findings + 7 new = 67 considered; merged 11 overlapping pairs).

## 5. Triage recommendation

Andrew is triaging, not committing to all fixes. Highest safety/correctness per line changed, in order:

1. Fix **#3** (one line removed at silitop:830, comment update). Eliminates the documented impossible-arithmetic case immediately.
2. Fix **#1** + **#10** + **#11** together by adding `pm_proc.poll()` + a SIGTERM handler. Roughly 15 lines. Collapses three independent CRIT/HIGH paths into one robust lifecycle.
3. Fix **#6** by switching to `tempfile.mkstemp` and removing the glob-cleanup. About 10 lines. Closes the security CRIT and the cross-instance-deletion HIGH simultaneously.
4. Fix **#2** by returning `None`/unavailable from `get_ram_metrics` on subprocess failure and rendering "Memory: unavailable." About 8 lines + 1 test rewrite. Removes the most user-visible incorrect-reading case and unblocks rewriting the misleading test.
5. Fix **#14** + **#27** together: case-fold the prefix comparison in `_is_efficiency` and add an M1 fixture test. About 5 lines + 1 test. Restores documented M1-M4 correctness.
6. Fix **#8** by parameterizing the time-scaled constants on `args.interval`. About 10 lines. Removes the silently-wrong-after-`--interval` class of bugs.
7. Fix **#5** + **#18** + **#19** together in `silitop-fans.swift`: differentiate confirmed-fanless from broken-AppleSMC, decode `fpe2` correctly, and only latch `fan_available=False` on the confirmed contract. About 30 lines of Swift but unblocks all fan-related correctness.
8. Fix **#7** by adding `install -o root -g wheel` and a PATH-shadow assertion in `install.sh`. About 5 lines. Closes the root-execution surface.
9. Fix **#23** by switching to `active + wired + compressed` accounting (or whichever Activity Monitor variant Andrew validates on his machine). About 6 lines.
10. Rewrite **#2**'s misleading test as part of **#4** above. Same change.

Items #4-#10 share the same underlying theme (Theme 1: fail-open-to-zero). If Andrew picks just the top three (CRIT-3, CRIT-1, CRIT-6) that is roughly 25 lines for the highest-leverage corrections.

## Coverage notes

- Verified by reading source end-to-end: `silitop` (1208 lines), `silitop-temps.swift` (92 lines), `silitop-fans.swift` (134 lines), `install.sh` (64 lines), `tests/test_layout.py` (311 lines).
- Verified by file inspection: every codex finding's `file:line` citation that I could check against the source. I did not see any case where a codex finding cited a line that did not match my source read.
- Verified analytically: SEAM-1 (the powermetrics-death-plus-orphan chain), SEAM-2 (interval double-divide), SEAM-3 (fan latch), SEAM-5 (interval contract), NEW-CRIT-1 (interval propagation), NEW-CRIT-2 (truthiness on 0.0), NEW-HIGH-1 (Popen retry leak), NEW-HIGH-2 (left/right column naming).
- Assumed without hardware verification: `fpe2` decoder behavior on actual SMC keys (codex `fan-reader:HIGH-1`); M1-M4 powermetrics cluster name capitalization (codex `soc-detection:HIGH-1`); `IOHIDServiceClientCopyEvent` field 0x000F0001 behavior on M5 Pro (codex `swift-temp-helper:HIGH-2`); root `powermetrics -o` flag semantics regarding symlink following (codex `safety-security:CRIT-1`). All retained at the codex severity because I could not raise or lower without hardware.
- Did not verify on hardware: anything requiring `sudo`, anything requiring live `powermetrics` output, anything requiring a writable `/opt/homebrew/bin`, anything requiring a CJK-width terminal, the `--test-temps` flag with real helpers, multi-instance launch behavior. The sandboxed audit machine cannot execute these without modifying state.
- Severity calls I made differently from codex: I promoted the codex MED `args.interval` issues to NEW-CRIT-1 because they silently corrupt power averaging, sparkline history coverage, and helper poll cadence simultaneously, which fits the project's CRIT definition ("incorrect readings the user trusts"). I demoted nothing.
