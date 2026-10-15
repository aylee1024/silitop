#!/bin/bash
# silitop installer.
#
# Run as your user, NOT under sudo. The script will sudo only for the
# install steps (cp + chown) so root never owns the build artifacts in
# the repo. The PATH-shadow check at the end fails the install when a
# stale silitop earlier on PATH would shadow the one we just placed.
#
# Usage:
#   bash install.sh             install / reinstall
#   bash install.sh --uninstall remove silitop and helpers from INSTALL_DIR
#
# Optional: set SILITOP_INSTALL_DIR to override the default /usr/local/bin.

set -e
set -u

INSTALL_DIR="${SILITOP_INSTALL_DIR:-/usr/local/bin}"

# Refuse sudo-rooted invocation; the audit found that "sudo bash install.sh"
# silently created root-owned build artifacts in the repo that future
# non-root rebuilds could not overwrite (audit #45).
if [[ "${EUID}" -eq 0 ]]; then
    echo "Error: do not run install.sh under sudo. Run as your user:" >&2
    echo "  bash install.sh" >&2
    echo "The script will sudo only the install steps internally." >&2
    exit 1
fi

# --uninstall path (audit #56): remove the three files from INSTALL_DIR.
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Removing silitop and helpers from ${INSTALL_DIR}..."
    sudo rm -f \
        "${INSTALL_DIR}/silitop" \
        "${INSTALL_DIR}/silitop-temps" \
        "${INSTALL_DIR}/silitop-fans"
    echo "Done."
    exit 0
fi

echo "silitop installer"
echo "================="
echo ""

if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: silitop only runs on macOS with Apple Silicon." >&2
    exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Error: silitop requires Apple Silicon (M1/M2/M3/M4/M5+)." >&2
    exit 1
fi
if ! command -v swiftc &>/dev/null; then
    echo "Error: Swift compiler not found. Install Xcode Command Line Tools:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 not found." >&2
    exit 1
fi
if [[ ! -x "/usr/bin/python3" ]]; then
    echo "Error: Native Apple Silicon /usr/bin/python3 not found." >&2
    exit 1
fi

echo "[1/4] Compiling helpers..."
swiftc -O silitop-temps.swift -o silitop-temps
swiftc -O silitop-fans.swift -o silitop-fans
echo "      Done."

# Verify helpers emit the v1 protocol header before we trust them.
# This is the boundary check from audit #47 (helper protocol versioning).
echo "[2/4] Verifying helper protocol..."
if ! ./silitop-fans 2>/dev/null | head -1 | grep -qx "silitop-fans v1"; then
    echo "Error: silitop-fans did not emit v1 header. Build mismatch?" >&2
    exit 1
fi
if ! ./silitop-temps 2>/dev/null | head -1 | grep -qx "silitop-temps v1"; then
    echo "Error: silitop-temps did not emit v1 header. Build mismatch?" >&2
    exit 1
fi
echo "      Done."

# install -o root -g wheel -m 0755 atomically copies+chowns+chmods. The
# prior `sudo cp` + `sudo chmod` left files owned by the invoking user on
# this M5 Pro (where /usr/local/bin is user:admin), exposing root
# execution to anyone with write access to /usr/local/bin (audit #7).
echo "[3/4] Installing to ${INSTALL_DIR}..."
sudo install -o root -g wheel -m 0755 silitop        "${INSTALL_DIR}/silitop"
sudo install -o root -g wheel -m 0755 silitop-temps  "${INSTALL_DIR}/silitop-temps"
sudo install -o root -g wheel -m 0755 silitop-fans   "${INSTALL_DIR}/silitop-fans"
echo "      Done."

# PATH-shadow check (audit #24). On Apple Silicon, /opt/homebrew/bin is
# typically ahead of /usr/local/bin in PATH. If an older silitop lives
# there, `sudo silitop` would resolve the shadow rather than what we
# just installed. Refuse to declare success in that case.
echo "[4/4] Verifying installation..."
resolved="$(command -v silitop || true)"
if [[ -z "${resolved}" ]]; then
    echo "      Warning: silitop not on PATH. Add ${INSTALL_DIR} to PATH." >&2
elif [[ "${resolved}" != "${INSTALL_DIR}/silitop" ]]; then
    echo "Error: PATH resolves to '${resolved}', not '${INSTALL_DIR}/silitop'." >&2
    echo "Remove the shadow binary or set SILITOP_INSTALL_DIR to a path" >&2
    echo "earlier on PATH, e.g. SILITOP_INSTALL_DIR=/opt/homebrew/bin bash install.sh" >&2
    exit 1
else
    echo "      silitop installed at ${resolved}"
fi

echo ""
echo "Installation complete. Run with:"
echo "  sudo silitop"
echo ""
echo "Options:"
echo "  --interval N   Sampling interval in seconds (default: 1)"
echo "  --color N      Color scheme 0-6 (default: 2/green)"
echo "  --avg N        Power averaging window in seconds (default: 30)"
echo "  --test-temps   Print temperature sensor readings and exit"
echo ""
echo "Uninstall:  bash install.sh --uninstall"
