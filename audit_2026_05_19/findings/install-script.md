# silitop audit — install-script

## Summary
The most important install-script bug is path coherence: `install.sh` hard-codes `/usr/local/bin`, but verifies “success” by accepting any `silitop` found earlier on `PATH`, so an older `/opt/homebrew/bin/silitop` can shadow the newly copied one. The sudo boundary is mostly correct for the documented `bash install.sh` path, because Swift compilation runs before the internal `sudo cp` calls, but the script does not defend against `sudo bash install.sh`, partial mixed-version installs, or stale installed files.

## Findings (ranked)

### HIGH-1: PATH shadowing can make the installer validate the wrong executable
- **Location:** `install.sh:4`, `install.sh:40-54`; runtime interaction at `silitop:299-310`
- **Mechanism:** Step by step:
  1. `INSTALL_DIR` is fixed to `/usr/local/bin` at `install.sh:4`.
  2. The script copies `silitop`, `silitop-temps`, and `silitop-fans` only into that directory at `install.sh:41-46`.
  3. Verification then runs `command -v silitop` and `which silitop` at `install.sh:50-51`, which search `PATH` instead of checking `${INSTALL_DIR}/silitop`.
  4. On this host, `/opt/homebrew/bin` exists and precedes `/usr/local/bin` in `PATH`. If an older `/opt/homebrew/bin/silitop` exists, verification succeeds against the old file.
  5. If that older front-end is invoked, `_find_helper()` first checks helpers next to that old script, then falls back to `/usr/local/bin` at `silitop:302-310`, so old Python can pair with old or new helpers.
- **Impact:** The installer can report success while the command the user resolves from `PATH` is not the file just installed. The observable effect is “I updated silitop, but I am still running the old front-end,” or a mixed front-end/helper version if helper output contracts change.
- **Repro:** On an Apple Silicon machine with `/opt/homebrew/bin` before `/usr/local/bin`, place any executable named `/opt/homebrew/bin/silitop`, then run `bash install.sh`. `install.sh:50-51` will validate the shadowing executable instead of `${INSTALL_DIR}/silitop`. Whether `sudo silitop` also resolves the shadow depends on the machine’s sudo `PATH`; I did not run sudo.
- **Fix sketch:** At `install.sh:4`, make the target configurable and prefer `/opt/homebrew/bin` when it exists and is on `PATH`, for example `SILITOP_INSTALL_DIR=${SILITOP_INSTALL_DIR:-...}`. At `install.sh:50-54`, compare `command -v silitop` to `"${INSTALL_DIR}/silitop"` and warn or fail if another path shadows it.

### MED-1: `sudo bash install.sh` compiles helpers as root
- **Location:** `install.sh:35-37`, `install.sh:41-46`
- **Mechanism:** Step by step:
  1. The README documents `bash install.sh`, and the script internally uses `sudo` only for copy/chmod at `install.sh:41-46`.
  2. If a user instead runs `sudo bash install.sh`, every line runs with effective UID 0.
  3. The Swift compiler invocations at `install.sh:36-37` then create or replace build outputs in the repo as root.
  4. In this checkout, `silitop-temps` is absent before install, so `sudo bash install.sh` would create at least that output as a root-created file.
- **Impact:** The repo can end up with root-owned build artifacts. Future non-sudo installs may fail or require manual cleanup before Swift can overwrite those outputs.
- **Repro:** Run `sudo bash install.sh`, then inspect `ls -l silitop-temps silitop-fans`. I did not execute this because it would modify the repo and system install path.
- **Fix sketch:** Add an EUID guard near `install.sh:2`: if `[[ "$EUID" -eq 0 ]]`, print “run `bash install.sh`, not `sudo bash install.sh`” and exit before `install.sh:35`.

### MED-2: Direct sequential copies can leave mixed installed versions after a failed install
- **Location:** `install.sh:2`, `install.sh:41-46`; runtime interaction at `silitop:743-744`
- **Mechanism:** Step by step:
  1. `set -e` at `install.sh:2` stops on the first failed command.
  2. Installation writes each component directly into the live target one at a time at `install.sh:41-46`.
  3. If `silitop` copies successfully but a later copy or chmod fails, the script exits with no rollback.
  4. On the next run, `silitop` resolves helper paths once at startup at `silitop:743-744`; missing helpers return empty readings at `silitop:316-317` and `silitop:336-337`.
- **Impact:** `/usr/local/bin` can contain a new Python front-end with old or missing helper binaries. The install failure is visible, but the installed tree remains inconsistent afterward.
- **Repro:** Trigger any failure after `install.sh:41`, for example an interrupt after the first copy, a protected target file, or a full target filesystem. Then inspect timestamps or checksums for `/usr/local/bin/silitop`, `/usr/local/bin/silitop-temps`, and `/usr/local/bin/silitop-fans`.
- **Fix sketch:** Replace `cp` plus `chmod +x` at `install.sh:41-46` with staged `install -m 0755` operations, then move all staged files into place only after all three staged writes succeed. At minimum, print a clear “partial install may have occurred” message on failure.

### LOW-1: There is no uninstall or stale-helper cleanup path
- **Location:** `install.sh:35-64`
- **Mechanism:** The script has one fixed flow: compile, copy three files, print usage. It does not parse `$1` or `$@`, so `bash install.sh --uninstall` still runs the installer, and reruns never remove obsolete helper names from earlier releases.
- **Impact:** Users have no supported way to remove the three installed files, and old helper binaries can remain in the install directory after a rename. Current runtime only looks for `silitop-temps` and `silitop-fans`, so this is mostly operational clutter unless a stale binary is invoked manually or shadows another path.
- **Repro:** Run `bash install.sh --uninstall`; the script still proceeds through `install.sh:35-64`.
- **Fix sketch:** Add a small argument case before `install.sh:35`: support `--uninstall` by removing `${INSTALL_DIR}/silitop`, `${INSTALL_DIR}/silitop-temps`, and `${INSTALL_DIR}/silitop-fans`; reject unknown arguments instead of ignoring them.

## What I verified vs assumed
- Verified: Read `/Users/andrewlee/.claude/CLAUDE.md`, `README.md`, and `install.sh` in full. `install.sh` has `set -e` at `install.sh:2`; checks Darwin and arm64 at `install.sh:10-20`; checks `swiftc` and `python3` at `install.sh:22-33`; compiles helpers with `swiftc -O` at `install.sh:35-37`; uses internal `sudo` only for copy/chmod at `install.sh:41-46`; makes installed files executable with `chmod +x` at `install.sh:42`, `install.sh:44`, and `install.sh:46`; has no uninstall branch. Runtime helper lookup checks the script directory first, then `/usr/local/bin`, at `silitop:299-310`. This host has `/opt/homebrew/bin` before `/usr/local/bin` in `PATH`, and both directories exist. `bash -n install.sh` passed.
- Assumed: A user may have an older `silitop` in `/opt/homebrew/bin` or another earlier `PATH` directory; I did not create one in system paths. `sudo bash install.sh` would create root-owned new compiler outputs; I did not execute it. Partial install failure can occur through interrupt, permission failure, or filesystem failure; I did not force one.
- Did not look at: Runtime behavior beyond helper path resolution and missing-helper returns. Code signing and notarization, because `install.sh` does not touch them.