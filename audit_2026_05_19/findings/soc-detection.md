# silitop audit — soc-detection

## Summary
The biggest risk is the first-letter tier classifier: under the M1-M4 output pattern I found in examples, `system_profiler` labels are lower-case `performance/efficiency`, while powermetrics cluster names are conventionally upper-case `P.../E...`; if that holds on target hardware, silitop classifies every M1-M4 efficiency cluster as performance. M5 Pro detection is mostly coherent on this host, but the subsystem silently falls back to plausible guesses instead of surfacing incomplete SoC detection.

## Findings (ranked)

### HIGH-1: M1-M4 efficiency cores can be classified as performance due to case-sensitive prefixes
- **Location:** `silitop:71-80`, `silitop:199-200`, `silitop:213-214`
- **Mechanism:** `get_soc_info()` parses tier words from `system_profiler` and stores the first character directly as `slow_prefix`. On M1-M4, the observed `system_profiler` format is `6 performance and 2 efficiency`, so `slow_prefix` becomes lowercase `e`. Later `_is_efficiency()` tests `name[0] == slow_prefix`. If powermetrics reports `E-Cluster`, that comparison is `E == e`, false, so the efficiency cluster is put into `p_cores`.
- **Impact:** Per-core CPU buckets, aggregate P/E activity, labels, and frequencies become wrong on documented M1-M4 machines. The user would see efficiency activity under the performance side and an empty or zeroed efficiency side.
- **Repro:** On an M1-M4 Mac where `system_profiler SPHardwareDataType` returns lower-case `performance/efficiency` and powermetrics cluster names begin with `E` and `P`, call `extract_cpu()` with `soc["slow_prefix"] == "e"` and a cluster named `E-Cluster`.
- **Fix sketch:** At `silitop:199-200`, normalize both sides and guard empty names: `return bool(name) and name[0].casefold() == slow_prefix[0].casefold()`. Also normalize display prefixes to uppercase at `silitop:79-80`.

### HIGH-2: SoC name has no `system_profiler` fallback when `machdep.cpu.brand_string` fails
- **Location:** `silitop:49-56`, `silitop:58-82`, `silitop:111-124`
- **Mechanism:** The code reads the SoC name only from `sysctl -n machdep.cpu.brand_string`. If that raises, it leaves `info["name"]` as `Apple Silicon`. The later `system_profiler SPHardwareDataType` pass parses only `Total Number of Cores`; it ignores the `Chip:` line even when present. Then the TDP bucket checks `name` for `Ultra`, `Max`, and `Pro`, so a Pro/Max/Ultra host with failed `sysctl` is treated as base.
- **Impact:** Header SoC name becomes generic. Power scaling also falls into the base bucket, for example an M5 Pro becomes CPU/GPU max `20/20` instead of the Pro branch `30/30`.
- **Repro:** In this sandbox on the M5 Pro host, `sysctl -n machdep.cpu.brand_string` returned `Operation not permitted`, while `system_profiler SPHardwareDataType` printed `Chip: Apple M5 Pro`. Importing and calling `get_soc_info()` returned `name: Apple Silicon`, `p_core_count: 6`, `e_core_count: 12`, `gpu_core_count: 20`, `cpu_max_power: 20`, `gpu_max_power: 20`.
- **Fix sketch:** In the loop at `silitop:63-80`, also parse lines beginning with `Chip:` and set `info["name"]` when the sysctl name is still the default.

### MED-1: Detection failure returns guessed 4+4 Super/Perf instead of an explicit unknown state
- **Location:** `silitop:38-48`, `silitop:81-98`
- **Mechanism:** The initial state is a concrete topology, `4` slow cores, `4` fast cores, `Super/Perf` labels, and `S/P` prefixes. Every detection call catches broad `Exception` and continues. If `system_profiler` is missing, localized, timed out, or returns a new format, and the perflevel sysctls are also missing, the function returns those defaults as if they were detected.
- **Impact:** On older macOS, virtualized hosts, or unsupported Apple Silicon-like environments, silitop can show a believable but fabricated SoC topology. For M1-M4, the fallback labels violate the README rule of `Efficiency/Performance`.
- **Repro:** Make `system_profiler SPHardwareDataType` fail or omit `Total Number of Cores`, and make `hw.perflevel0.logicalcpu` or `hw.perflevel1.logicalcpu` unavailable. `get_soc_info()` still returns the initial 4+4 Super/Perf values.
- **Fix sketch:** At `silitop:38-48`, initialize counts and labels to unknown sentinels, or track `core_counts_detected` and `tier_labels_detected`. Only render concrete labels after one source actually populated them.

### MED-2: The core-count fallback uses `logicalcpu`, which is not the stable topology key
- **Location:** `silitop:84-96`
- **Mechanism:** The code falls back to `hw.perflevel0.logicalcpu` and `hw.perflevel1.logicalcpu`. Apple’s local SDK documents `hw.perflevelN.logicalcpu` as processors available in the current power management mode, and `hw.perflevelN.logicalcpumax` as the maximum available this boot. For a hardware topology display, current availability is the weaker signal.
- **Impact:** If macOS ever reports fewer currently available CPUs under a power mode, hot-plug-like state, or virtualization layer, silitop would display runtime availability as installed core count.
- **Repro:** I did not reproduce reduced availability on hardware. The issue follows from the documented meaning of the sysctl names in `/Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk/usr/include/sys/sysctl.h:675-684`.
- **Fix sketch:** At `silitop:89` and `silitop:94`, use `hw.perflevelN.logicalcpumax` or `hw.perflevelN.physicalcpu` for topology, not `logicalcpu`.

### LOW-1: The parser relies on exact English `system_profiler` wording
- **Location:** `silitop:64-71`, `silitop:105-107`
- **Mechanism:** CPU and GPU parsing both search for the literal English string `Total Number of Cores`. CPU parsing also requires `N Word and M Word`; it would not parse `6 performance cores and 2 efficiency cores`, localized output, or a multi-word tier name.
- **Impact:** Future macOS wording or localized profiler output would push the function into the guessed fallback path.
- **Repro:** Change the hardware line to `Total Number of Cores: 8 (6 performance cores and 2 efficiency cores)` or localize `and`; `re.match()` at `silitop:71` fails.
- **Fix sketch:** At `silitop:71`, tolerate optional `core(s)` after each tier word and make failure explicit instead of silently preserving defaults.

## What I verified vs assumed
- Verified: `silitop` reads exactly these sysctl keys in scope: `machdep.cpu.brand_string` at `silitop:51`, `hw.perflevel0.logicalcpu` at `silitop:89`, and `hw.perflevel1.logicalcpu` at `silitop:94`.
- Verified: `machdep.cpu.brand_string` is listed in the local macOS sysctl man page at `/usr/share/man/man8/sysctl.8:289`; `hw.perflevelN.logicalcpu` and `logicalcpumax` are documented in Apple’s local SDK header at `/Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk/usr/include/sys/sysctl.h:675-684`.
- Verified: On this M5 Pro host, `system_profiler SPHardwareDataType` reports `Chip: Apple M5 Pro` and `Total Number of Cores: 18 (6 Super and 12 Performance)`; `SPDisplaysDataType` reports `Total Number of Cores: 20`.
- Verified: Actual `/tmp/silitop_pm1779079908` powermetrics data on this host contains cluster names `P0-Cluster`, `P1-Cluster`, and `S-Cluster`; with M5 labels, `slow_prefix == "P"` correctly selects the slow Performance clusters.
- Verified: There is no SoC-family regex for `Apple M1` through `Apple M5 Pro`; brand strings are only substring-bucketed for power estimates at `silitop:113-124`: base names fall to `else`, `Pro` to Pro, `Max` to Max, `Ultra` to Ultra, and `Air` would also fall to base.
- Verified from Apple Support: M1-M4 specs use performance/efficiency terminology, and M5 uses super/performance terminology: https://support.apple.com/en-euro/111902, https://support.apple.com/en-us/117736, https://support.apple.com/en-us/121554, https://support.apple.com/en-ie/126318.
- Assumed: M1-M4 powermetrics cluster names begin with uppercase `E` and `P`; I did not run this on M1-M4 hardware.
- Assumed: `system_profiler` output order for M1-M4 is performance first, efficiency second, based on examples and Apple’s spec wording; I did not verify on local M1-M4 machines.
- Did not look at: Curses rendering of the SoC label, powermetrics plist parsing correctness beyond the cluster-name evidence needed for `_is_efficiency`, or power-estimate accuracy.