#!/bin/bash
# Build and install the native silitop executable.
# Run as your user; sudo is used only for the final atomic install.

set -euo pipefail

INSTALL_DIR="${SILITOP_INSTALL_DIR:-/usr/local/bin}"

if [[ "${EUID}" -eq 0 ]]; then
    echo "Error: do not run install.sh under sudo. Run as your user:" >&2
    echo "  bash install.sh" >&2
    echo "The script will sudo only the install steps internally." >&2
    exit 1
fi

if [[ "${1:-}" == "--uninstall" ]]; then
    echo "Removing silitop from ${INSTALL_DIR}..."
    sudo rm -f \
        "${INSTALL_DIR}/silitop" \
        "${INSTALL_DIR}/silitop-temps" \
        "${INSTALL_DIR}/silitop-fans"
    echo "Done."
    exit 0
fi

if [[ $# -ne 0 ]]; then
    echo "Usage: bash install.sh [--uninstall]" >&2
    exit 2
fi

echo "silitop installer"
echo "================="
echo ""

if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: silitop only runs on macOS with Apple Silicon." >&2
    exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Error: silitop requires Apple Silicon (M1 or later)." >&2
    exit 1
fi

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "${macos_major}" -lt 13 ]]; then
    echo "Error: silitop requires macOS 13 Ventura or later." >&2
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    echo "Error: Swift compiler not found. Install Xcode Command Line Tools:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi
if ! command -v strip >/dev/null 2>&1; then
    echo "Error: strip not found. Install Xcode Command Line Tools." >&2
    exit 1
fi

echo "[1/3] Building optimized native executable..."
BUILD_PATH="$(mktemp -d "${TMPDIR:-/tmp}/silitop-build.XXXXXX")"
STAGED_PATH=""
cleanup() {
    if [[ -n "${STAGED_PATH}" ]]; then
        sudo rm -f "${STAGED_PATH}"
    fi
    rm -rf "${BUILD_PATH}"
}
trap cleanup EXIT HUP INT TERM
swift build -c release --product silitop --build-path "${BUILD_PATH}"
BIN_DIR="$(swift build -c release --show-bin-path --build-path "${BUILD_PATH}")"
BINARY="${BIN_DIR}/silitop"
if [[ ! -x "${BINARY}" ]]; then
    echo "Error: release build did not produce ${BINARY}." >&2
    exit 1
fi
strip "${BINARY}"
echo "      Done."

echo "[2/3] Installing atomically to ${INSTALL_DIR}..."
sudo mkdir -p "${INSTALL_DIR}"
STAGED_PATH="${INSTALL_DIR}/.silitop-install.$$"
sudo install -o root -g wheel -m 0755 "${BINARY}" "${STAGED_PATH}"
sudo mv -f "${STAGED_PATH}" "${INSTALL_DIR}/silitop"
STAGED_PATH=""
# Remove helper binaries left by upgrades from the Python implementation.
sudo rm -f "${INSTALL_DIR}/silitop-temps" "${INSTALL_DIR}/silitop-fans"
echo "      Done."

echo "[3/3] Verifying installation..."
resolved="$(command -v silitop || true)"
if [[ -z "${resolved}" ]]; then
    echo "      Warning: silitop is not on PATH. Add ${INSTALL_DIR} to PATH." >&2
elif [[ "${resolved}" != "${INSTALL_DIR}/silitop" ]]; then
    echo "Error: PATH resolves to '${resolved}', not '${INSTALL_DIR}/silitop'." >&2
    echo "Remove the shadow binary or install to an earlier PATH directory." >&2
    exit 1
else
    echo "      silitop installed at ${resolved}"
fi

echo ""
echo "Installation complete. Run with:"
echo "  sudo silitop"
echo ""
echo "Uninstall: bash install.sh --uninstall"
