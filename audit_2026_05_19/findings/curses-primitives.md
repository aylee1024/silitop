# silitop audit — curses-primitives

## Summary
The most important defect is that `clamp_pct` is not actually safe for missing or non-finite values: `None` and `NaN` raise before clamping, and the drawing callers do not catch that. I found no CRIT or HIGH issue in the scoped primitives. The subsystem is small and mostly bounded, but it relies on percent inputs, narrow Unicode rendering, and tests that miss the riskiest boundary cases.

## Findings (ranked)

### MED-1: `clamp_pct` crashes on `None` and `NaN`
- **Location:** `silitop:503-505`, callers at `silitop:511`, `silitop:605`, `silitop:651`, `silitop:683`
- **Mechanism:** `clamp_pct` calls `int(pct)` before validating the input. `None` raises `TypeError`; `float("nan")` raises `ValueError`. The row drawing functions call `clamp_pct` directly, so the exception propagates out of the curses draw path. Negative numeric values and values above 100 do clamp correctly after conversion.
- **Impact:** A missing or non-finite percentage value can terminate the dashboard instead of rendering a safe 0% or 100%. I did not verify that current `powermetrics` output produces `None` or `NaN`; this is a primitive-level failure.
- **Repro:** Load `silitop` with `SourceFileLoader`, then call `SILITOP.clamp_pct(None)` or `SILITOP.clamp_pct(float("nan"))`.
- **Fix sketch:** At `silitop:503`, convert through `float`, reject `None` and non-finite values, then clamp: `if pct is None: return 0`; `if not math.isfinite(float(pct)): return 0`; then `max(0, min(int(pct), 100))`.

### MED-2: Unicode clipping assumes one terminal column per glyph
- **Location:** `silitop:23`, `silitop:548-563`, `silitop:570-594`, `silitop:711-717`, entry at `silitop:1204`
- **Mechanism:** `safe_addstr` clips by `len(s)`, and the layout code also counts Python characters, not terminal cells. The block, sparkline, box, degree, and arrow glyphs used here have East Asian Width `A` when checked with Python `unicodedata`, meaning their rendered cell width is locale or terminal-policy dependent. If curses or the terminal renders them as width 2, the code writes more cells than it budgeted. `safe_addstr` then catches `curses.error` and silently drops the failed write.
- **Impact:** On ambiguous-wide or bad-locale terminals, bars, boxes, sparklines, and temperature text can overflow, collide with suffixes, or disappear without an error message.
- **Repro:** Run under a terminal/profile that treats East Asian Ambiguous characters as wide, or under a non-UTF-8 curses locale. I did not verify this on a live CJK-width terminal in this audit.
- **Fix sketch:** Before `curses.wrapper` at `silitop:1204`, call `locale.setlocale(locale.LC_ALL, "")`. In `safe_addstr` and `compute_bar_layout`, clip by display cells rather than `len`; for zero dependency, add a tiny local width helper for the fixed glyph set or fall back to ASCII bars when the locale is not UTF-8/narrow.

### MED-3: `temp_color(70)` contradicts the README threshold
- **Location:** `README.md:22`, `silitop:531-539`
- **Mechanism:** The README specifies `cyan < 50C, yellow 50-70C, red > 70C`. The code uses `if temp < 70: return 3`, then falls through to red, so exactly `70` returns color pair 4.
- **Impact:** A 70C reading is rendered red even though the documented range says it should still be yellow.
- **Repro:** `temp_color(69.9)` returns 3; `temp_color(70)` returns 4.
- **Fix sketch:** Change `silitop:537` to `if temp <= 70:` if the README is authoritative. Otherwise change `README.md:22` to say red `>= 70C`.

### MED-4: Tests miss the risky primitive boundaries
- **Location:** `tests/test_layout.py:57-135`
- **Mechanism:** The tests cover `compute_bar_layout` overlap, and suffix preservation for `draw_core_row`, `draw_fan_row`, and `draw_hbar_full`. They do not directly test `init_colors`, `hbar`, `clamp_pct`, `temp_color`, `draw_box`, `safe_addstr`, or `draw_spark`. They also do not test `None`, `NaN`, exact 70C, negative `hbar` percentages, Unicode cell width, or `safe_addstr` clipping with non-ASCII strings.
- **Impact:** The current test suite passes while the defects above remain undetected.
- **Repro:** `PYTHONDONTWRITEBYTECODE=1 python3 tests/test_layout.py` runs 12 tests and passes.
- **Fix sketch:** Add focused unit tests in `tests/test_layout.py` for the listed primitives, especially `clamp_pct(None)`, `clamp_pct(float("nan"))`, `temp_color(70)`, `hbar(10, -10)`, `safe_addstr` clipping, and `draw_spark([], 0)` / `draw_spark([1], 0)`.

### LOW-1: `hbar` is dead and can return more characters than `width`
- **Location:** `silitop:23`, `silitop:494-500`
- **Mechanism:** `BLOCK_CHARS = " ▏▎▍▌▋▊▉█"` is defined but `hbar` does not use it; it only emits full and empty characters. It also caps `fill` at `width` but never floors it at 0. With `width=10` and `pct=-10`, `fill` becomes `-1`, so the empty side repeats `11` times.
- **Impact:** No current runtime impact, because I found no `hbar` calls outside its definition. If reused, it can overflow its advertised width and it does not provide the 8-step partial-column behavior implied by `BLOCK_CHARS`.
- **Repro:** `hbar(10, -10)` returns 11 characters; `hbar(10, 99.9)` returns 9 full blocks and 1 empty block, with no partial column.
- **Fix sketch:** Either delete `BLOCK_CHARS` and `hbar` if unused, or rewrite `hbar` at `silitop:494` to clamp the lower bound and implement the partial-block sequence explicitly.

## What I verified vs assumed
- Verified: I read `/Users/andrewlee/.claude/CLAUDE.md`, `README.md`, `silitop:481-721`, and `tests/test_layout.py`.
- Verified: Current callers use 0-100 percentages, not 0-1 ratios: CPU at `silitop:217`, GPU at `silitop:261`, RAM at `silitop:459`, fans at `silitop:910`, ANE at `silitop:951`.
- Verified: `compute_bar_layout(5, 50, "ABCDEF", " 100%")` produces zero-width bar and suffix spans without overlap.
- Verified: `draw_spark` handles empty `values`, `max_val=0`, shorter histories, longer histories, and values above `max_val` for the asked cases.
- Verified: `init_colors` allocates pairs 1-7 without pair-index collision at `silitop:485-491`; `bg` from `COLOR_SCHEMES` is unused because all pairs use `-1`.
- Verified: `draw_box` passes attributes per `addstr` call, so I found no attr-on/attr-off leak.
- Assumed: Some user terminals may render East Asian Ambiguous glyphs as width 2; I verified the Unicode property, not a live terminal rendering.
- Assumed: Current runtime data sources normally pass numeric percentages into these primitives; I did not prove `powermetrics` can emit `None` or `NaN` on the M5 Pro host.
- Did not look at: main-loop lifecycle beyond primitive call sites, Swift helpers, installer behavior, and color-scheme aesthetics outside the documented temperature thresholds.