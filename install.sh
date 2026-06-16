#!/usr/bin/env bash
# Tailscale Termux Local Builder & Installer
# Detects host architecture, compiles binaries, generates completions/services, packages them as a .deb, and installs it.
set -eu

echo "Tailscale Termux Local Builder & Installer"
echo "========================================="

# 1. Detect architecture
HOST_ARCH=$(go env GOARCH 2>/dev/null || echo "")
if [ -z "$HOST_ARCH" ]; then
    # Fallback to uname if go is not installed yet
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) TARGET_ARCH="aarch64" ;;
        armv7l|armv8l|arm) TARGET_ARCH="arm" ;;
        i686|i386|386) TARGET_ARCH="i686" ;;
        x86_64|amd64) TARGET_ARCH="x86_64" ;;
        *)
            echo "Error: Unsupported architecture $ARCH"
            exit 1
            ;;
    esac
else
    case "$HOST_ARCH" in
        arm64) TARGET_ARCH="aarch64" ;;
        arm)   TARGET_ARCH="arm"     ;;
        386)   TARGET_ARCH="i686"    ;;
        amd64) TARGET_ARCH="x86_64"  ;;
        *)     TARGET_ARCH="aarch64" ;;
    esac
fi

# 2. Build the deb package
echo "-> Building package for $TARGET_ARCH..."
chmod +x ./build_deb.sh ./build.sh
./build_deb.sh "$TARGET_ARCH"

# 3. Find the built deb package
DEB_FILE=$(ls dist/tailscale-termux_*_${TARGET_ARCH}.deb 2>/dev/null | head -n 1)
if [ -z "$DEB_FILE" ]; then
    echo "Error: Generated .deb package not found in dist/"
    exit 1
fi

# 4. Install via dpkg + apt
echo "-> Installing package: $DEB_FILE..."
# Stop existing daemon if running
pkill -f tailscaled || true

dpkg -i "$DEB_FILE"
if command -v apt >/dev/null 2>&1; then
    echo "-> Checking/fixing dependencies..."
    apt install -f -y
fi

echo "========================================="
echo "Local Installation Complete!"
echo "To start the daemon, run: tailscaled-start"
echo "To authenticate, run: tailscale-cli up"
echo "========================================="
