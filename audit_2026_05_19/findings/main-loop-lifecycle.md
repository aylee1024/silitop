# silitop audit — main-loop-lifecycle

## Summary
The worst problem is powermetrics lifecycle handling: once the UI has drawn real data, it does not verify that the powermetrics child is still alive or that the file is still advancing, so failures can leave stale readings onscreen with no error. Normal-loop structure is simple and bounded, colors are initialized once, and histories are capped, but the subsystem repeatedly treats data-source failure as “no data yet” or “zero” instead of surfacing it.

## Findings (ranked)

### CRIT-1: Dead or stalled powermetrics leaves stale readings onscreen
- **Location:** `silitop:776-794`, `silitop:1163-1172`
- **Mechanism:** Each loop calls `parse_powermetrics(pm_path)`. If parsing returns the previous plist, `ts == last_timestamp` triggers `time.sleep(0.1)` and skips redraw. If the file disappears after `waiting` has become `False`, `parsed is None` triggers `time.sleep(0.5)` and skips redraw. The loop never calls `pm_proc.poll()`, never checks file mtime, and never reports that the data source died.
- **Impact:** The dashboard can keep showing old CPU, GPU, power, network, disk, memory, and temperature values as if they are live. That is an incorrect reading the user trusts.
- **Repro:** Run `sudo silitop`, wait for data, then from another shell kill only the powermetrics child, for example `sudo pkill -P <silitop_pid> powermetrics`. The curses screen remains on the last successful frame instead of showing a fatal data-source error.
- **Fix sketch:** In `silitop:776-794`, check `pm_proc.poll()` before accepting `None` or a repeated timestamp. Track `last_success_monotonic`; if no new sample arrives after a bounded multiple of `args.interval`, draw an explicit “powermetrics stopped” message and break into the existing cleanup path at `silitop:1163-1172`.

### CRIT-2: RAM subprocess failure is displayed as 0 GB used
- **Location:** `silitop:407-409`, `silitop:410-465`, `silitop:1010-1015`
- **Mechanism:** `get_ram_metrics()` initializes all RAM fields to zero, catches every exception from `vm_stat`, and returns the zero-filled dict. The main loop then formats those fields directly as a valid memory reading.
- **Impact:** A failed `vm_stat` call becomes `Memory: 0/<total> GB (0%)`, which is a silently degraded reading to zero.
- **Repro:** Put a failing `vm_stat` earlier in `PATH` while leaving `sysctl` available, then run `sudo env PATH=<failing-dir>:/usr/bin:/usr/sbin silitop`. The code path is also codified by `tests/test_layout.py:293-307`.
- **Fix sketch:** Change `get_ram_metrics()` at `silitop:410-465` to return an error status or `None` when `vm_stat` fails. In `silitop:1010-1015`, render “Memory: unavailable” instead of formatting zero defaults.

### HIGH-1: SIGTERM bypasses cleanup and can leave powermetrics running
- **Location:** `silitop:10-19`, `silitop:1163-1172`, `silitop:1176-1204`
- **Mechanism:** The file imports no `signal` module and installs no SIGTERM handler. The cleanup is only in `main()`’s `finally`. A SIGTERM sent to the Python parent uses the default process action, so Python does not unwind into that `finally`.
- **Impact:** The privileged powermetrics child can continue running, and `/tmp/silitop_pm*` files can remain.
- **Repro:** Run `sudo silitop`, then `sudo kill -TERM <silitop_pid>`. Check `pgrep -fl powermetrics` and `ls /tmp/silitop_pm*`.
- **Fix sketch:** In `entry()` before `curses.wrapper` at `silitop:1204`, install SIGTERM handling that requests loop shutdown through a flag, or raises `KeyboardInterrupt`, so execution reaches `silitop:1163-1172`.

### HIGH-2: Global `/tmp/silitop_pm*` cleanup makes instances destroy each other
- **Location:** `silitop:131-133`, `silitop:737-738`, `silitop:1169-1172`
- **Mechanism:** Startup deletes every `/tmp/silitop_pm*` file, then chooses a path based on `int(time.time())`. Shutdown again deletes every matching file. A second instance can remove the first instance’s active output path. If both start in the same second, they can also target the same path.
- **Impact:** One instance can force another into the stale-data path from CRIT-1. It also makes cleanup non-local: quitting one process deletes another process’s live data file.
- **Repro:** Start `sudo silitop`, wait for data, then start another `sudo silitop`. The second process runs `glob("/tmp/silitop_pm*")` cleanup before creating its own file.
- **Fix sketch:** Replace `silitop:737-738` with a unique per-process temp path from `tempfile`, for example a private `silitop_pm_<pid>_<random>` file. Remove only `pm_path` in `silitop:1169-1172`; do not glob-delete the shared prefix.

### HIGH-3: Invalid argparse values can start powermetrics and then crash before cleanup
- **Location:** `silitop:738`, `silitop:750-752`, `silitop:770`, `silitop:1180-1185`
- **Mechanism:** `--interval` and `--avg` accept any integer. `pm_proc` starts at `silitop:738`, but the protecting `try` does not begin until `silitop:770`. `--avg -1` makes `deque(maxlen=-1)` raise before the `finally`; `--interval 0` can divide by zero at `silitop:750`.
- **Impact:** Bad user input can crash the Python process after launching powermetrics, bypassing cleanup and leaving the child or temp files behind.
- **Repro:** Run `sudo silitop --avg -1` or `sudo silitop --interval 0`.
- **Fix sketch:** Validate positive integers in `entry()` at `silitop:1180-1185` before calling `curses.wrapper`. Also move the `try/finally` so it begins immediately after `pm_proc` is assigned at `silitop:738`.

### HIGH-4: Slow helpers block the entire UI loop
- **Location:** `silitop:811`, `silitop:814-818`, `silitop:319-320`, `silitop:339-340`, `silitop:411`, `silitop:467`
- **Mechanism:** The render loop is single-threaded. Every new powermetrics sample calls `get_ram_metrics()`. Every third sample calls `read_hid_temps()` and then `read_fan_speeds()`. The temperature and fan helpers each have a 3 second timeout, so they can block serially for about 6 seconds. `vm_stat` and `sysctl vm.swapusage` have no timeout.
- **Impact:** While a helper blocks, curses does not redraw and `q`/Esc are not processed. At the default interval, one bad slow-poll cycle can freeze the UI for multiple frames.
- **Repro:** Replace the local `silitop-temps` or `silitop-fans` helper with a script that sleeps longer than 3 seconds, then run `sudo silitop`.
- **Fix sketch:** Add short timeouts to the RAM subprocesses at `silitop:411` and `silitop:467`. For helpers at `silitop:814-818`, cache last-known values and surface timeout status instead of blocking the render path for the full helper timeout.

### MED-1: Locale is not initialized before curses emits Unicode
- **Location:** `silitop:10-19`, `silitop:548`, `silitop:711`, `silitop:1204`
- **Mechanism:** The program draws Unicode box characters and sparklines, but never imports `locale` or calls `locale.setlocale(locale.LC_ALL, "")` before `curses.wrapper`.
- **Impact:** Under `LC_ALL=C` or a sudo environment that strips UTF-8 locale variables, curses can miscompute character widths or fail to render glyphs. Because drawing helpers swallow `curses.error`, parts of the UI can disappear silently.
- **Repro:** Run `sudo env LC_ALL=C LANG=C silitop` in a terminal that otherwise supports UTF-8.
- **Fix sketch:** In `entry()` before `silitop:1204`, call `locale.setlocale(locale.LC_ALL, "")` and explicitly warn or exit if the active encoding is not UTF-8.

### MED-2: Resize is handled only incidentally
- **Location:** `silitop:772-774`, `silitop:851-852`
- **Mechanism:** `getch()` only handles `q` and Esc. `KEY_RESIZE` is ignored. The code reads `getmaxyx()` only after a fresh powermetrics sample has passed the stale-timestamp checks.
- **Impact:** Resize redraw is delayed until the next successful sample. If powermetrics is stale or lost, resizing never repairs the screen.
- **Repro:** Run `sudo silitop --interval 5`, resize immediately after a redraw, and observe that the old layout persists until the next accepted sample.
- **Fix sketch:** In `silitop:772-774`, handle `curses.KEY_RESIZE` by updating curses’ size state, erasing, and forcing a redraw from the last parsed snapshot.

### LOW-1: Sparkline history is fixed, not matched to actual width
- **Location:** `silitop:747-768`, `silitop:707-713`, `silitop:971-999`, `silitop:1065-1077`
- **Mechanism:** All histories use `maxlen=120`. Drawing slices the last `w` values, but does not resize, pad, or rebuild histories when terminal width changes.
- **Impact:** Narrow terminals keep unused offscreen history, which is harmless. Very wide terminals can leave available sparkline space blank once width exceeds 120 samples.
- **Repro:** Use a very wide terminal, wider than the fixed history length available to a sparkline.
- **Fix sketch:** Keep this unless the visual gap matters. If it matters, recompute history `maxlen` from the largest sparkline width and preserve the newest samples during resize.

## What I verified vs assumed
- Verified: `entry()` handles `--test-temps` before the root check, non-root normal startup exits with two printed lines, and `curses.wrapper` is used at `silitop:1204`.
- Verified: there is no locale setup, no signal handling, and no `KEY_RESIZE` handling in `silitop`.
- Verified: color pairs are initialized once at `silitop:726`, not per frame.
- Verified: `get_ram_metrics()` runs every accepted powermetrics sample; HID temperatures and fans run every third accepted sample.
- Verified: q and Esc break into `finally`, which terminates and waits for powermetrics on the normal path.
- Verified: the kill fallback calls `pm_proc.kill()` but does not call a second `wait()` afterward.
- Verified: histories are `deque(maxlen=120)` and are not recreated each frame.
- Assumed: SIGTERM is sent to the Python process only, not to the whole foreground process group.
- Assumed: deleting an active powermetrics output path follows normal Unix unlink semantics; I did not attach to powermetrics to verify its exact file descriptor behavior.
- Assumed: helper hangs and `LC_ALL=C` rendering failures are reproducible on the target M5 Pro host; I traced the code paths but did not run the UI under sudo.
- Did not look at: individual draw primitive correctness, powermetrics plist parsing internals beyond lifecycle effects, Swift helper internals, and `install.sh`.