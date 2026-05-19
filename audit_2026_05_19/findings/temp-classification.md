# silitop audit — temp-classification

## Summary
The main problem is that temperature collection has no distinguishable failure state: helper timeout, nonzero exit, stderr-only failure, decode failure, missing helper, and genuinely empty sensor output all collapse to `{}`, then the UI hides the temperature pane. Classification itself is a narrow M5 Pro heuristic, not a general Apple Silicon classifier; the hardcoded “last 2 `PMU tdie` zones are GPU” rule is the riskiest correctness issue.

## Findings (ranked)

### HIGH-1: Helper failures are silently converted into “no temperatures”
- **Location:** `silitop:313-330`, `silitop:813-823`, `silitop:1083-1149`
- **Mechanism:** `read_hid_temps` runs `[helper]` with `timeout=3` and `stderr=subprocess.DEVNULL`. `check_output` raises on timeout or nonzero exit. The broad `except Exception` swallows that and returns `{}`. The main loop overwrites `hid_temps` with that empty dict every third cycle. `classify_temps({})` returns empty CPU/GPU/other groups, and the UI takes the `has_temps == False` path.
- **Impact:** A transient helper failure makes all temperature readings disappear with no user-visible error. It does not render zeros; it hides the temperature pane and keeps only thermal pressure.
- **Repro:** Run on a machine where `silitop-temps` exits nonzero, times out, emits undecodable output, or prints nothing. Direct unit repro: call `read_hid_temps("/bin/false")`, it returns `{}` instead of surfacing failure.
- **Fix sketch:** At `silitop:318-330`, use `subprocess.run(..., capture_output=True, text=True, timeout=3)` and return a distinct failure sentinel, for example `None`, on timeout/nonzero/decode errors. At `silitop:813-815`, only replace `hid_temps` on a successful read, and render “Temperatures unavailable” when the helper fails.

### HIGH-2: CPU/GPU die split is hardcoded to an unverified M5 Pro layout
- **Location:** `silitop:363-390`, `silitop:823`; context `README.md:28`, `README.md:101-102`
- **Mechanism:** `classify_temps` defaults `gpu_die_zones=2`. The only caller uses the default. The function sorts every `PMU tdieN` sensor by `N`, assigns the last two zones to GPU, and assigns the rest to CPU. The README documents Apple Silicon broadly, but also says M1-M4 need validation.
- **Impact:** On any documented platform variant whose GPU zones are not exactly the last two `PMU tdie` indices, CPU and GPU temperature labels become wrong. If a chip exposes more than two GPU zones, the earlier GPU zones are labeled CPU. If it exposes exactly two die zones total, both are labeled CPU because the split only runs when `len(all_die) > gpu_die_zones`.
- **Repro:** `classify_temps({"PMU tdie1": 40, "PMU tdie2": 41, "PMU tdie3": 60, "PMU tdie4": 61}, gpu_die_zones=2)` labels zones 1-2 CPU and 3-4 GPU regardless of the actual chip map.
- **Fix sketch:** At `silitop:363`, remove the general-looking default or derive it from a tested SoC map. At `silitop:823`, pass an explicit `gpu_die_zones` from `soc` only when validated; otherwise label the section “Die zones” rather than CPU/GPU.

### MED-1: SSD and battery classification only recognizes two exact M5-style names
- **Location:** `silitop:356-384`
- **Mechanism:** `SENSOR_LABELS` normalizes only `"NAND CH0 temp"` to `SSD` and `"gas gauge battery"` to `Battery`. It discards `"PMU tcal"`. Any other non-`PMU tdie` and non-`PMU tdev` sensor name is ignored silently.
- **Impact:** If another Apple Silicon machine reports SSD or battery sensors under different names, those readings disappear even though the helper parsed them successfully.
- **Repro:** `classify_temps({"NAND CH1 temp": 45.0, "gas gauge battery 0": 31.0})` returns no SSD or battery entry.
- **Fix sketch:** At `silitop:356-384`, either add tested aliases from `--test-temps` fixtures or preserve unmatched known thermal sensors under their raw names instead of dropping them.

### MED-2: Parser drops malformed lines without diagnostics and cannot handle `|` in names
- **Location:** `silitop:321-327`; Swift output source `silitop-temps.swift:82-83`
- **Mechanism:** The Swift helper prints `name|temp`. Python parses with `line.split("|", 1)`. Blank lines and lines with no delimiter are ignored. Missing trailing newline is fine. Non-ASCII names work only if Python’s implicit text decoding succeeds. If a sensor name contains `|`, the parser treats the text after the first pipe as the temperature and drops the line when `float(...)` fails.
- **Impact:** One malformed sensor line silently loses that sensor. A decode failure loses the entire helper output because it is caught by the broad exception path.
- **Repro:** A helper line `PMU|tdie1|55.0` is ignored; a helper line `PMU tdie1|55.0` is accepted.
- **Fix sketch:** At `silitop:321-327`, parse from the right with `line.rsplit("|", 1)`, track skipped-line count, and expose it in `--test-temps`.

## What I verified vs assumed
- Verified: `read_hid_temps` shells out with no shell, uses a 3 second timeout, suppresses stderr, catches all regular exceptions, and returns `{}` on failure.
- Verified: the main loop polls temperatures every third parsed powermetrics cycle, not every UI refresh, and reuses the last value only between those polls.
- Verified: empty sensor output does not crash and does not render zeros; it hides the temperature box and renders only thermal pressure.
- Verified: `SENSOR_LABELS` normalizes `"NAND CH0 temp"` and `"gas gauge battery"`, discards `"PMU tcal"`, and drops other unmatched names.
- Verified: the Swift helper’s output format is `name|temperature` from `silitop-temps.swift:82-83`.
- Assumed: the “last two die zones are GPU” rule matches the current M5 Pro host, because I did not validate the physical zone map against Apple documentation or hardware telemetry.
- Assumed: Max/Ultra or older chips may expose different die-zone counts or ordering; I did not have those machines to verify.
- Did not look at: the Swift helper’s IOKit internals, by scope instruction.