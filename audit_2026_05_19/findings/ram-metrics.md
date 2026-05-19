# silitop audit — ram-metrics

## Summary
The code does not have the classic Apple Silicon 4K-page bug; it parses the `vm_stat` page-size header and uses 16K on this host. The serious weakness is that RAM collection failures and ambiguous `vm_stat` accounting become valid-looking readings. The preferred formula also treats all `File-backed pages` as reclaimable cache, which I do not think is justified for an Activity Monitor-style “Memory Used” number without further validation.

## Findings (ranked)

### CRIT-1: RAM collection failures become fake zero, full, or inactive readings
- **Location:** `silitop:407-465`, `silitop:466-475`, `silitop:811`
- **Mechanism:** `get_ram_metrics` initializes `used_gb`, `pct`, swap, and breakdown fields to zero at `silitop:407-409`. If `vm_stat` raises, the broad `except Exception` at `silitop:464-465` returns those zeros as if they were measured. If `vm_stat` exits successfully with empty output, no fields are parsed at `silitop:417-425`; the legacy branch at `silitop:449-452` computes `used_pages = total_pages`, so RAM becomes 100% used. If `sysctl -n vm.swapusage` fails or does not match the regex, `silitop:474-475` leaves swap at zero.
- **Impact:** The dashboard can show `0%` RAM used, `100%` RAM used, or “Swap: inactive” during data-collection failure. That is not a degraded display; it is an incorrect reading the user will trust.
- **Repro:** Mock `subprocess.check_output` so `["vm_stat"]` raises `FileNotFoundError`; the existing test at `tests/test_layout.py:293-307` asserts the current zero-output behavior. Mock `["vm_stat"]` to return `""`; the function reports full RAM usage because `free_display` remains zero.
- **Fix sketch:** At `silitop:410-465`, treat missing/empty `vm_stat` as unavailable, not as numeric data. Return an explicit invalid status or `None`, and at `silitop:811` keep the previous valid RAM sample or render unavailable. Do the same for swap at `silitop:466-475`, so a swap parser failure cannot mean “inactive.”

### HIGH-1: Preferred used-memory formula treats all file-backed pages as cache
- **Location:** `silitop:400-404`, `silitop:431-443`, `silitop:460-463`
- **Mechanism:** The preferred branch uses `free_display = free + spec + file_backed + purge` at `silitop:442`, then sets `used_pages = total_pages - free_display` at `silitop:443`. That classifies every `File-backed pages` page as available/cache. The local `vm_stat` man page defines `File-backed pages` as total file-backed non-swap pages, not as inactive cached files. Apple’s Activity Monitor guide separates “Memory Used” into App, Wired, and Compressed, with Cached Files separate: https://support.apple.com/en-ae/guide/activity-monitor/actmntr1004/mac. The code also never reads `Pages active`, even though the audit target specifically calls out active versus inactive classification.
- **Impact:** Workloads with substantial active file-backed memory, for example mapped files, shared libraries, or file-backed app data, can be underreported as cache/free. On a live spot check on this M5 Pro host, using the code’s formula against `vm_stat` gave 21.3 GiB used; `active + wired + compressor` gave 27.0 GiB. That is a spot check, not an Activity Monitor UI verification.
- **Repro:** Feed a synthetic `vm_stat` sample where `Pages active`, `Pages wired down`, and `Pages occupied by compressor` stay constant while `File-backed pages` increases. The current branch decreases `used_pages` solely because `file_backed` increased.
- **Fix sketch:** At `silitop:431-443`, parse `Pages active` explicitly and use the project’s intended Activity Monitor mapping. If the target is the definition in the prompt, compute `used_pages = active + wired + (compressed or 0)` and put inactive/speculative/purgeable into the reclaimable side. Do not subtract raw `File-backed pages` as a blanket cache bucket.

### MED-1: Missing individual `vm_stat` fields silently turn into zeros
- **Location:** `silitop:431-463`
- **Mechanism:** Required counters such as `Pages free`, `Pages speculative`, `Pages wired down`, and `Pages purgeable` use `f.get(..., 0)` at `silitop:431-435`. Breakdown fields also default to zero at `silitop:460-463`. A partial parser miss therefore becomes a plausible measured value, not an error. For example, if `Pages occupied by compressor` is missing while `File-backed pages` exists, total used still renders but `compressed_gb` becomes `0`.
- **Impact:** A macOS output change or truncated command output can corrupt one bucket while the rest of the RAM display looks healthy.
- **Repro:** Remove `Pages occupied by compressor:` from `tests/test_layout.py:140-157` and call `get_ram_metrics`; `compressed_gb` becomes zero without a failure signal.
- **Fix sketch:** At `silitop:431-438`, keep required fields as `None` until validated. Select a formula only after its full field set is present, and mark missing breakdown buckets unavailable instead of rendering zero.

### MED-2: RAM polling spawns two unbounded subprocesses per sample
- **Location:** `silitop:411`, `silitop:467`, `silitop:811`, `silitop:1180`
- **Mechanism:** `main` calls `get_ram_metrics` once per powermetrics sample at `silitop:811`. The default interval is 1 second at `silitop:1180`. Each call runs `vm_stat` at `silitop:411` and `sysctl -n vm.swapusage` at `silitop:467`, both without `timeout=`.
- **Impact:** This is two RAM-related subprocesses per second by default. I did not measure this as >10% CPU, so I am not calling it HIGH. The real risk is that a hung or shadowed command blocks the curses refresh loop indefinitely.
- **Repro:** Put a fake `vm_stat` earlier in `PATH` that sleeps, then run silitop in that environment; the loop blocks inside `subprocess.check_output`.
- **Fix sketch:** At `silitop:411` and `silitop:467`, call absolute paths (`/usr/bin/vm_stat`, `/usr/sbin/sysctl`) with a short timeout. Cache or slow-poll swap if per-second swap refresh is not needed.

## What I verified vs assumed
- Verified: I read `/Users/andrewlee/.claude/CLAUDE.md` and the project `README.md` in full.
- Verified: `get_ram_metrics` parses the dynamic page size with `re.search(r"page size of (\d+)", vm)` at `silitop:413-415`; live `vm_stat` on this host reports `page size of 16384 bytes`.
- Verified: The parser handles colon-separated `vm_stat` lines, strips periods and commas, and parses current fields at `silitop:417-425`.
- Verified: `hw.memsize` is called once in `main` at `silitop:740-742`, then passed into `get_ram_metrics` at `silitop:811`; the function treats it as bytes at `silitop:406` and `silitop:430`.
- Verified: Swap parsing only accepts `M` units via regexes at `silitop:468-473`, matching the prompt example and tests at `tests/test_layout.py:159` and `tests/test_layout.py:287-291`.
- Verified: `python3 tests/test_layout.py` passed 12 tests. `pytest` was not installed.
- Assumed: `sysctl -n hw.memsize` returns bytes on the target unsandboxed macOS system. In this sandbox, direct `sysctl` calls failed with `Operation not permitted`, so I could not verify that command live.
- Assumed: The HIGH-1 formula issue should be judged against the prompt’s Activity Monitor definition and Apple’s public Activity Monitor category description. I did not compare against the live Activity Monitor UI, so I marked it HIGH rather than CRIT.
- Did not look at: Curses rendering of the memory bar, temperature/fan helpers, powermetrics parsing outside the RAM call path.