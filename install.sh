#!/bin/bash
set -e

INSTALL_DIR="/usr/local/bin"

echo "silitop installer"
echo "================="
echo ""

# Check macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: silitop only runs on macOS with Apple Silicon."
    exit 1
fi

# Check Apple Silicon
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Error: silitop requires Apple Silicon (M1/M2/M3/M4/M5+)."
    exit 1
fi

# Check Swift compiler
if ! command -v swiftc &>/dev/null; then
    echo "Error: Swift compiler not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

# Check Python 3
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 not found."
    exit 1
fi

echo "[1/3] Compiling temperature reader..."
swiftc -O silitop-temps.swift -o silitop-temps
echo "      Done."

echo "[2/3] Installing to ${INSTALL_DIR}..."
sudo cp silitop "${INSTALL_DIR}/silitop"
sudo chmod +x "${INSTALL_DIR}/silitop"
sudo cp silitop-temps "${INSTALL_DIR}/silitop-temps"
sudo chmod +x "${INSTALL_DIR}/silitop-temps"
echo "      Done."

echo "[3/3] Verifying installation..."
if command -v silitop &>/dev/null; then
    echo "      silitop installed at $(which silitop)"
else
    echo "      Warning: silitop not found in PATH. Add ${INSTALL_DIR} to your PATH."
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
