# silitop audit — powermetrics-parsing

## Summary
The current plist key names mostly match the local `/usr/bin/powermetrics` binary on this M5 Pro, but the subsystem has one concrete unit bug: `processor.combined_power` is already a power value, yet silitop divides it by the sampling interval again, so package/total watts are wrong for non-1-second intervals. The parser is otherwise simple and mostly correct for NUL-separated plist samples, but it treats missing sampler fields as real zeros, which is unsafe for a monitoring tool.

## Findings (ranked)

### CRIT-1: Package watts are divided by the sampling interval twice
- **Location:** `silitop:247`, `silitop:826-830`
- **Mechanism:** `extract_cpu` reads `processor.combined_power` and divides by 1000 at `silitop:247`. I verified the local powermetrics binary contains `combined_power` as a power field, with nearby text reporting combined power in mW. Then the main loop divides `cpu_agg["package_w"]` by `args.interval` again at `silitop:830`. At the default interval of 1 second, this is hidden. At `--interval 2`, total/package watts are cut in half.
- **Impact:** The displayed `Total` watts and package peak are wrong whenever `--interval` is not 1. The UI can show `CPU: 10W  GPU: 5W  Total: 7.5W`, which is mechanically impossible.
- **Repro:** Run `sudo silitop --interval 2` under load and compare `Total` against `processor.combined_power / 1000` from the powermetrics plist, or against CPU+GPU+ANE watts.
- **Fix sketch:** At `silitop:830`, use `pkg_w = cpu_agg["package_w"]` without interval division. Update the comment around `silitop:243-247` so only `*_energy` fields are described as interval-normalized.

### CRIT-2: Missing sampler keys become trusted zeros
- **Location:** `silitop:205-207`, `silitop:239-247`, `silitop:251-263`, `silitop:270-285`
- **Mechanism:** Missing `processor`, `gpu`, `network`, or `disk` sections are replaced with `{}`. Missing CPU clusters become empty lists, then aggregate active/frequency values become `0` through `max(len(...), 1)`. Missing GPU becomes `idle_ratio=1`, so active is `0`. Missing network/disk rates become `0`.
- **Impact:** If powermetrics omits a sampler section or Apple renames a key, silitop reports authoritative-looking zero CPU/GPU/network/disk values instead of showing unavailable or failing the sample.
- **Repro:** Feed `{"timestamp": "x"}` into `extract_cpu`, `extract_gpu`, `extract_network`, and `extract_disk`; the result is all zero-like readings.
- **Fix sketch:** Validate required top-level sampler sections after `parse_powermetrics` at `silitop:776` before extraction. Return an unavailable state or skip the sample when required keys are absent. Do not use `0` as the default for required plist fields.

### HIGH-1: Permanent powermetrics startup failure becomes an infinite waiting screen
- **Location:** `silitop:139-167`, `silitop:776-789`
- **Mechanism:** `run_powermetrics` waits 1.5 seconds for the first two attempts. If every sampler set exits, it starts a final process at `silitop:158-166` and returns it without checking whether it also immediately failed. The main loop only watches the plist file, so it keeps rendering “Waiting for powermetrics data...” forever.
- **Impact:** A sampler rename, unsupported sampler, or powermetrics startup error is masked as a data wait. The user gets no stderr or actionable failure.
- **Repro:** On current host, the first `smc` sampler attempt is unsupported but the second attempt recovers. To trigger the full bug, make the fallback sampler invalid too, or run on a macOS where one requested sampler is unavailable.
- **Fix sketch:** After the final `Popen` at `silitop:165-166`, wait briefly as in the loop. If it exits, read stderr and raise or render a startup error. Also check `pm_proc.poll()` in the waiting path at `silitop:776-789`.

### MED-1: Missing or malformed CPU cluster name crashes extraction
- **Location:** `silitop:199`, `silitop:211-214`, `silitop:799`
- **Mechanism:** `cluster.get("name", "")` can produce an empty string. `_is_efficiency` immediately indexes `name[0]`, so a missing or empty name raises `IndexError`. The exception is not caught around `extract_cpu`.
- **Impact:** One malformed or future-schema cluster entry exits the dashboard instead of skipping the sample or showing unavailable CPU data.
- **Repro:** Call `extract_cpu({"processor": {"clusters": [{"cpus": []}]}}, {"slow_prefix": "E"})`.
- **Fix sketch:** At `silitop:199`, guard the string before indexing, for example `return bool(name) and name[0] == slow_prefix`. Prefer treating a missing cluster name as an invalid sample rather than silently assigning it to the fast bucket.

### MED-2: Non-finite and negative numeric fields are not sanitized
- **Location:** `silitop:217-224`, `silitop:253-263`, `silitop:270-296`
- **Mechanism:** `int((1 - idle_ratio) * 100)` raises on `NaN`. GPU frequency also reaches `int(freq)`. Negative network/disk rates pass through `format_rate` and histories as negative throughput.
- **Impact:** Invalid plist values can crash the dashboard or display nonsensical negative I/O rates. I did not verify live powermetrics emits NaN here; this is an edge-case robustness issue.
- **Repro:** `extract_gpu({"gpu": {"idle_ratio": float("nan"), "freq_hz": 0}})` raises. `format_rate(-1)` returns `-1 B/s`.
- **Fix sketch:** Add a small numeric sanitizer near `silitop:203` or inside each extractor: require `math.isfinite`, clamp percentages to `0..100`, and clamp rates/frequencies to `>= 0` or mark them unavailable.

## What I verified vs assumed
- Verified: Read `/Users/andrewlee/.claude/CLAUDE.md` and `README.md` in full.
- Verified: Local `powermetrics --help` says plist output is NUL-separated and lists `cpu_power`, `gpu_power`, `thermal`, `network`, and `disk` samplers.
- Verified: Local `/usr/bin/powermetrics` string templates contain the plist keys silitop reads: `processor.clusters`, `freq_hz`, `idle_ratio`, `cpu_energy`, `gpu_energy`, `ane_energy`, `combined_power`, `gpu.freq_hz`, `thermal_pressure`, `network.ibyte_rate`, `network.obyte_rate`, `disk.rbytes_per_s`, and `disk.wbytes_per_s`.
- Verified: `parse_powermetrics` handles multiple complete NUL-separated samples by scanning chunks in reverse, and skips a partial trailing chunk.
- Verified: `_find_helper` handles installed `/usr/local/bin` when running installed, handles repo-local dev helpers, and chooses the repo-local helper if both exist.
- Assumed: CPU `freq_hz` is Hz and GPU `freq_hz` is MHz-or-Hz depending on value; I could not capture a live root plist sample in this sandbox.
- Assumed: `cpu_energy`, `gpu_energy`, and `ane_energy` are millijoules per sample, consistent with the existing code and asitop behavior.
- Assumed: Negative underflow rates may be possible because the powermetrics binary contains network/disk underflow warning strings; I did not verify emitted plist values.
- Did not look at: `get_soc_info`, temperature sensor labeling/classification, curses layout/rendering, subprocess security, or `/tmp` race behavior.