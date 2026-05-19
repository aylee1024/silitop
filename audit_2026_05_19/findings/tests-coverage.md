# silitop audit — tests-coverage

## Summary
The suite is narrow: it tests bar suffix layout and RAM accounting only (`tests/test_layout.py:57-135`, `tests/test_layout.py:172-307`). The most serious problem is that one test explicitly blesses silent RAM degradation to zero on subprocess failure (`tests/test_layout.py:293-307`), which is the wrong contract for a monitor whose readings users trust. There is useful coverage for `vm_stat` arithmetic, including one M5 Pro snapshot, but there is no recorded `powermetrics` fixture, no SoC/core-tier coverage, no helper parser coverage, no temperature threshold coverage, and no CI config.

## Findings (ranked)

### CRIT-1: RAM failure test pins silent zero readings
- **Location:** `tests/test_layout.py:293-307`, `silitop:397-476`
- **Mechanism:** The test patches `SILITOP.subprocess.check_output` so every subprocess call raises `FileNotFoundError`. `get_ram_metrics()` catches the failure and returns default zeros for used RAM, percent, breakdown, and swap. The test then asserts those zeros as correct behavior.
- **Impact:** If `vm_stat` or `sysctl vm.swapusage` fails in real use, the UI can report `0` used RAM and `0%` usage instead of surfacing that RAM collection failed.
- **Repro:** Run `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_layout.py`; the failure-path zeroing test passes.
- **Fix sketch:** Replace `tests/test_layout.py:293-307` with a test that requires an explicit unavailable state, for example `available=False` or `used_gb is None`, and a separate test that swap failure does not zero valid RAM metrics.

### HIGH-1: No test covers powermetrics plist ingestion
- **Location:** `tests/test_layout.py:57-307`, `silitop:170-196`, `silitop:203-285`, `silitop:776-811`
- **Mechanism:** The main loop reads a plist sample with `parse_powermetrics()`, then extracts CPU, GPU, thermal, network, and disk fields. The test file never calls `parse_powermetrics()`, `extract_cpu()`, `extract_gpu()`, `extract_thermal()`, `extract_network()`, or `extract_disk()`. There is no recorded plist sample.
- **Impact:** A parser regression can make CPU, GPU, power, thermal pressure, network, or disk readings wrong or empty while all tests still pass.
- **Repro:** Change `extract_network()` to read the wrong keys at `silitop:273-275`, then run `python3 -m unittest tests/test_layout.py`; the suite still passes because the function is untested.
- **Fix sketch:** Add one recorded null-delimited plist fixture and one test class after `tests/test_layout.py:307` that asserts `parse_powermetrics()` returns the latest complete sample and that the extractors return fixed expected values.

### HIGH-2: SoC and core-tier detection are untested across documented platforms
- **Location:** `tests/test_layout.py:57-307`, `silitop:36-126`, `silitop:199-248`
- **Mechanism:** `get_soc_info()` parses `system_profiler` and `sysctl` output for core counts and labels. `extract_cpu()` then uses `_is_efficiency(name, soc["slow_prefix"])` to bucket clusters. The suite has no mocked M1, M2, M3, M4, or M5 hardware strings and no direct `_is_efficiency()` or `extract_cpu()` bucket assertions.
- **Impact:** A mapping regression can swap or mislabel fast and slow cores on a documented platform variant while layout and RAM tests stay green.
- **Repro:** Invert `_is_efficiency()` at `silitop:199-200`, then run `python3 -m unittest tests/test_layout.py`; no existing test observes the change.
- **Fix sketch:** Add two mocked `subprocess.check_output` tests: one M1-style `"Efficiency and Performance"` profile and one M5-style `"Super and Performance"` profile. Add one `extract_cpu()` fixture per naming scheme to assert bucket counts and aggregate values.

### MED-1: Swift helper parsers and helper lookup have no coverage
- **Location:** `tests/test_layout.py:57-307`, `silitop:299-353`, `silitop-temps.swift:82-83`, `silitop-fans.swift:129-133`
- **Mechanism:** `_find_helper()` search order is untested. `read_hid_temps()` and `read_fan_speeds()` parse pipe-delimited helper output and swallow malformed lines, timeouts, and subprocess failures. No test mocks helper stdout, missing helpers, malformed values, or local-vs-system binary resolution.
- **Impact:** Temperature and fan readings can disappear without a failing test if the helper output contract changes or helper resolution picks the wrong binary.
- **Repro:** Change `line.split("|", 1)` at `silitop:322` to split on a comma, then run the suite; all tests still pass.
- **Fix sketch:** Add small tests with mocked `subprocess.check_output` for valid temp lines, invalid temp lines, valid fan lines, invalid fan lines, timeout behavior, and mocked `os.path.isfile` for `_find_helper()` local-first lookup.

### MED-2: UI utility coverage misses threshold and resize edge cases
- **Location:** `tests/test_layout.py:57-135`, `silitop:503-539`, `silitop:707-717`, `silitop:746-768`
- **Mechanism:** `clamp_pct()` is only covered indirectly for over-100 input. There are no direct tests for negative values, float truncation, or invalid types. `temp_color()` thresholds at `<50`, `<70`, and `>=70` are untested. `draw_spark()` and the fixed `deque(maxlen=120)` histories are untested for terminal resize behavior.
- **Impact:** Bar clamping, temperature colors, or sparkline rendering can become misleading without test failures. This is mostly display correctness, not data collection correctness.
- **Repro:** Change `temp_color(70)` to return yellow instead of red at `silitop:537-539`; the current tests still pass.
- **Fix sketch:** Add parameterized pure unit tests for `clamp_pct(-1, 0, 99.9, 100, 145)`, `temp_color(-1, 49.9, 50, 69.9, 70)`, and `draw_spark()` with widths below, equal to, and above available history length.

### LOW-1: No CI configuration is present
- **Location:** repository root, no `.github/` directory found
- **Mechanism:** I found no GitHub Actions workflow or other YAML CI file under the repository. The tests only run when someone invokes them locally.
- **Impact:** Even the existing narrow suite is not enforced on pull requests or pushes.
- **Repro:** `find /Users/andrewlee/Desktop/Code/silitop/.github -maxdepth 3 -type f` returns “No such file or directory”.
- **Fix sketch:** Add a minimal macOS CI workflow that runs `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_layout.py`.

## What I verified vs assumed
- Verified: Function inventory under test is `compute_bar_layout()` for clamping and non-overlap (`tests/test_layout.py:57-72`), `draw_core_row()` for suffix preservation at 99, 100, and 145 percent (`tests/test_layout.py:74-94`), `draw_hbar_full()` for 100 and 145 percent suffix preservation (`tests/test_layout.py:96-111`), `draw_fan_row()` for percent/RPM suffix preservation (`tests/test_layout.py:114-135`), and `get_ram_metrics()` for one M5 Pro snapshot, synthetic formulas, clamping, swap parsing, and subprocess failure defaults (`tests/test_layout.py:172-307`).
- Verified: No test only asserts “no exception” by itself. The closest is the subprocess failure test, but it also asserts zero defaults (`tests/test_layout.py:293-307`).
- Verified: Platform isolation is partial. RAM subprocess calls are mocked (`tests/test_layout.py:173-176`); curses colors are monkeypatched (`tests/test_layout.py:37-50`); drawing uses `FakeWindow` (`tests/test_layout.py:15-33`). The mocks do not exercise real curses, real helpers, real `powermetrics`, or real `system_profiler`.
- Verified: The suite is deterministic with respect to time, locale, and terminal size. It uses fixed fake window sizes and fixed text fixtures. Runtime from `/usr/bin/time` was `real 0.19s`; unittest reported `Ran 12 tests in 0.002s`.
- Verified: Highest-ROI new tests, ranked, are: recorded `powermetrics` fixture covering parser plus extractors; mocked M1/M5 SoC and core bucket tests; helper parser and `_find_helper()` tests; direct threshold tests for `clamp_pct()` and `temp_color()`; minimal CI workflow.
- Assumed: I treated untested `powermetrics` and helper parsing as high impact because README says those paths supply CPU/GPU/power/thermal/network/disk/temp/fan readings (`README.md:53-70`). I did not run live `sudo powermetrics` or the real helpers.
- Did not look at: Production-code correctness beyond tracing coverage targets; real hardware sensor output; real curses rendering in a terminal; install behavior beyond confirming no CI file was present.