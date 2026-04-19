#!/usr/bin/env bash
set -eu

echo "Tailscale Termux CLI Installer"
echo "=============================="

# This script assumes you already have the precompiled binaries
# (either from GitHub Actions or built locally via build.sh)
# and want to install them into your Termux environment.

BIN_DIR="$HOME/bin"
SV_DIR="$PREFIX/var/service/tailscaled"
SRC_BIN_DIR="bin"

if [ ! -d "$SRC_BIN_DIR" ]; then
    echo "Error: 'bin' directory not found."
    echo "Please download the artifacts from GitHub Actions or run build.sh first."
    exit 1
fi

echo "[1/3] Installing binaries to $BIN_DIR..."
mkdir -p "$BIN_DIR"
cp "$SRC_BIN_DIR/tailscaled-termux" "$BIN_DIR/tailscaled"
cp "$SRC_BIN_DIR/tailscale-termux" "$BIN_DIR/tailscale"
chmod +x "$BIN_DIR/tailscaled" "$BIN_DIR/tailscale"

echo "[2/3] Setting up Termux Services (sv)..."
if command -v sv >/dev/null 2>&1; then
    echo "-> termux-services detected. Installing service scripts."
    mkdir -p "$SV_DIR/log"
    cp -r termux-services/tailscaled/* "$SV_DIR/"
    chmod +x "$SV_DIR/run" "$SV_DIR/log/run"
    
    echo "-> Creating default state directory..."
    mkdir -p "$HOME/.tailscale"
    
    echo "-> Enabling tailscaled service..."
    sv-enable tailscaled || true
else
    echo "-> 'termux-services' not installed. Skipping service setup."
    echo "   You can install it later with 'pkg install termux-services'."
fi

echo "[3/3] Installation Complete!"
echo "=============================="
echo "To start the daemon manually in the background:"
echo "  mkdir -p ~/.tailscale"
echo "  ~/bin/tailscaled --statedir=~/.tailscale --tun=userspace-networking --socks5-server=localhost:1055 &"
echo
echo "If you installed termux-services, start it with:"
echo "  sv start tailscaled"
echo
echo "To authenticate:"
echo "  ~/bin/tailscale up"
