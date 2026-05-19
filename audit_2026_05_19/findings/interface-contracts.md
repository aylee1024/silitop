# silitop audit — interface-contracts

## Summary
The main interface problem is fail-open parsing: missing powermetrics keys, missing helpers, helper crashes, decode failures, and format mismatches all collapse into empty data or zero-valued readings with no visible “unavailable” state. The subsystem is compact and consistently wired, but the contracts are implicit strings and dict keys, not checked protocols. I found no current CRIT issue from code alone; the highest-severity issues are HIGH because I did not verify a live M5 Pro powermetrics schema failure on hardware.

## Findings (ranked)

### HIGH-1: Powermetrics schema drift silently becomes trusted zero readings
- **Location:** `silitop:203-284`
- **Mechanism:** `parse_powermetrics` returns a plist dict, then `extract_cpu`, `extract_gpu`, `extract_network`, and `extract_disk` use `.get(..., 0)` or `.get(..., {})` for nearly every schema key. The code relies on these powermetrics keys: top-level `timestamp`, `processor`, `gpu`, `thermal_pressure`, `network`, `disk`; under `processor`, `clusters`, `cpu_energy`, `gpu_energy`, `ane_energy`, `combined_power`; under each cluster, `name`, `freq_hz`, `cpus`; under each CPU, `idle_ratio`, `freq_hz`, `cpu`; under `gpu`, `idle_ratio`, `freq_hz`; under `network`, `ibyte_rate`, `obyte_rate`; under `disk`, `rbytes_per_s`, `wbytes_per_s`. Single-point failures are `processor`, `processor.clusters`, `gpu`, `network`, and `disk`, because absence makes a whole panel empty or zero. Energy and rate keys are also single-point failures for their displayed numbers.
- **Impact:** If macOS renames or omits a key, CPU/GPU activity, frequency, power, network, or disk can render as `0` without telling the user the data source failed. `thermal_pressure` degrades to `Unknown`, which is at least distinguishable.
- **Repro:** Import `silitop` and call `extract_gpu({})`, `extract_network({})`, `extract_disk({})`, or `extract_cpu({}, {"slow_prefix": "E"})`; each returns zeros or empty lists instead of an unavailable/error state. A live repro would require a powermetrics plist with one of the listed keys renamed or absent.
- **Fix sketch:** At `silitop:203`, `silitop:251`, `silitop:266`, `silitop:270`, and `silitop:279`, validate required keys before defaulting. Return an explicit unavailable status for missing required keys, and at `silitop:798-810` render “unavailable” rather than zero for panels whose source schema failed.

### HIGH-2: Helper failures and missing helper binaries are silent
- **Location:** `silitop:299-353`, `silitop:813-821`, `silitop-temps.swift:89-92`, `silitop-fans.swift:107-113`
- **Mechanism:** `_find_helper` returns `None` when a helper is absent. `read_hid_temps` and `read_fan_speeds` immediately return `{}` or `[]` for `None`; they also run helpers with `stderr=subprocess.DEVNULL` and catch all exceptions. Python uses `check_output`, so a helper that exits `1` after printing valid stdout triggers an exception and the valid lines are discarded. The Swift helpers explicitly exit `0` for handled fan no-data cases, and the temperature helper falls off the end with process exit `0` when it finds nothing.
- **Impact:** Missing helper, helper crash, decode failure, timeout, no sensors, and malformed output are indistinguishable. Temperatures disappear from the UI. Fans are worse: if the first fan poll returns empty, `fan_available` becomes `False` at `silitop:818-819`, so the program stops trying for the rest of that run.
- **Repro:** Start without `silitop-temps` in the script directory or `/usr/local/bin`; `_find_helper("silitop-temps")` returns `None`, then `read_hid_temps(None)` returns `{}`. For the exit-code case, make a helper print `FAN0|1200|6500` and exit `1`; `check_output` raises, `read_fan_speeds` catches it, and the fan list is empty.
- **Fix sketch:** At `silitop:319` and `silitop:339`, use `subprocess.run(..., capture_output=True, encoding="utf-8", check=False, timeout=3)` and parse stdout if present while recording return code and stderr. At `silitop:316` and `silitop:336`, return a status that distinguishes missing helper from no readings. At `silitop:818-819`, do not permanently disable fans after one empty result unless the helper returned a successful “no fans” status.

### MED-1: The Swift helper line protocol is unescaped and locale-sensitive
- **Location:** `silitop-temps.swift:83`, `silitop-fans.swift:133`, `silitop:321-327`, `silitop:341-350`
- **Mechanism:** Temperature output is `sensor_name|temp`, parsed with `line.split("|", 1)`. If a sensor name contains `|`, Python treats the rest of the name plus the temperature as the numeric field and drops the line on `ValueError`. If a sensor name contains a newline, `splitlines()` turns one sensor into multiple records and can either drop it or mislabel the suffix as the sensor name. Fan names are currently generated as `FAN\(i)`, so delimiter/newline risk is not real for fan names today. Numeric output uses `String(format:)` without an explicit POSIX locale; Python `float()` accepts `42.1`, not `42,1`.
- **Impact:** A weird IOHID sensor name or comma-decimal helper output silently loses temperature rows. This is not proven on the current M5 Pro host, but the code has no protection against it.
- **Repro:** Synthetic helper output `PMU|tdie0|42.0` is dropped by `read_hid_temps`; `PMU\ntdie0|42.0` can be parsed as sensor `tdie0`; `PMU tdie0|42,0` is dropped by `float()`.
- **Fix sketch:** At `silitop-temps.swift:83`, escape or encode sensor names before printing, and format numbers with `Locale(identifier: "en_US_POSIX")`. At `silitop:321-327`, decode the escaped name and reject malformed rows as protocol errors, not just `pass`.

### MED-2: No protocol version makes helper changes unsafe
- **Location:** `silitop-temps.swift:83`, `silitop-fans.swift:133`, `silitop:321-350`
- **Mechanism:** There is no version or header line. The current Swift source emits exactly the Python-expected columns, so this is a future risk, not a current mismatch. If temps add a column, `float(parts[1])` sees `42.0|extra` and drops the row. If fans add a column, `len(parts) == 3` fails and drops the row.
- **Impact:** A helper update can remove all temp or fan readings without a clear incompatibility error.
- **Repro:** Synthetic output `PMU tdie0|42.0|ok` is ignored by the temp parser; `FAN0|1200|6500|ok` is ignored by the fan parser.
- **Fix sketch:** Add a first line such as `SILITOP_TEMPS_V1` and `SILITOP_FANS_V1` at `silitop-temps.swift:83` and `silitop-fans.swift:133`. At `silitop:321` and `silitop:341`, require the expected version before parsing rows and surface a version mismatch.

### LOW-1: Python does not pin UTF-8 when decoding helper stdout
- **Location:** `silitop:319-320`, `silitop:339-340`
- **Mechanism:** Swift `print` writes UTF-8 text, while Python `check_output(..., text=True)` decodes with the process locale encoding. The current shell locale I observed is `C.UTF-8`, so it matches now. Under a non-UTF-8 locale, a non-ASCII sensor name could raise `UnicodeDecodeError`, then the broad `except Exception` returns no readings.
- **Impact:** Rare environment-dependent loss of helper data.
- **Repro:** Run under a non-UTF-8 locale with a helper that prints a non-ASCII sensor name.
- **Fix sketch:** At `silitop:319` and `silitop:339`, pass `encoding="utf-8"` explicitly and do not swallow decode failures without recording status.

## What I verified vs assumed
- Verified: I read `/Users/andrewlee/.claude/CLAUDE.md` and `/Users/andrewlee/Desktop/Code/silitop/README.md` in full.
- Verified: Swift helper stdout is produced at `silitop-temps.swift:83` and `silitop-fans.swift:133`; neither helper has explicit stderr prints.
- Verified: Python parses temps with `split("|", 1)` and fans with exact three-column `split("|")`.
- Verified: Python suppresses helper stderr, catches all helper exceptions, and returns empty readings.
- Verified: `powermetrics` is persistent; both Swift helpers are fresh one-shot subprocesses every third loop cycle, from `silitop:813-821`.
- Verified: The powermetrics key list in HIGH-1 is exactly what `extract_*` and the main loop read.
- Assumed: Current M5 Pro powermetrics output still uses the expected key names. I did not run a live sudo powermetrics sample in this audit.
- Assumed: Current IOHID sensor names do not contain `|` or newlines. The Swift and Python code do not enforce that.
- Assumed: Comma-decimal Swift formatting is possible under some locales. I could not verify with `swift -e` because the read-only sandbox blocked Swift temp/cache creation; the observed shell locale was `C.UTF-8`.
- Did not look at: Internal correctness of the HID temperature extraction, SMC fan extraction, sudo/privilege behavior, curses layout behavior, `vm_stat` and `sysctl` parsers. I only searched layout tests for interface parser coverage; I did not audit layout tests.