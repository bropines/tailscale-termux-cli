#!/data/data/com.termux/files/usr/bin/env bash
# Tailscale Termux Remote Installer
# Automates downloading and installing the architecture-specific deb package.
set -eu

echo "Tailscale Termux Remote Installer"
echo "=============================="

echo "[*] Checking requirements..."
REQUIREMENTS=(
    "curl:curl"
    "wget:wget"
    "grep:grep"
    "dpkg:dpkg"
)

MISSING_PKGS=""
for req in "${REQUIREMENTS[@]}"; do
    cmd="${req%%:*}"
    pkg="${req##*:}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_PKGS="$MISSING_PKGS $pkg"
    fi
done

if [ -n "$MISSING_PKGS" ]; then
    echo " -> Installing missing dependencies:$MISSING_PKGS"
    pkg install -y $MISSING_PKGS
else
    echo " -> All installer dependencies are present."
fi

REPO="bropines/tailscale-termux-cli"

echo "[1/3] Fetching latest release info..."
LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')

if [ -z "$LATEST_TAG" ]; then
    echo "Error: No releases found."
    exit 1
fi
echo "-> Latest Release: $LATEST_TAG"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64)
        ARCH="aarch64"
        ;;
    armv7l|armv8l|arm)
        ARCH="arm"
        ;;
    i686|i386|386)
        ARCH="i686"
        ;;
    x86_64|amd64)
        ARCH="x86_64"
        ;;
    *)
        echo "Error: Unsupported architecture $ARCH"
        exit 1
        ;;
esac
echo "-> Detected architecture: $ARCH"

# Convert LATEST_TAG for deb version (e.g. v1.100.0 -> 1.100.0)
DEB_VERSION=$(echo "$LATEST_TAG" | sed 's/^v//' | tr '-' '.')
DEB_FILE="tailscale-termux_${DEB_VERSION}_${ARCH}.deb"
DEB_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/$DEB_FILE"

echo "[2/3] Downloading package: $DEB_FILE..."
# Create a temporary directory to download
TMP_DIR=$(mktemp -d "$HOME/tmp.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

wget -q --show-progress -O "$TMP_DIR/$DEB_FILE" "$DEB_URL"

echo "[3/3] Installing package via dpkg..."
# Stop existing daemon if running
pkill -f tailscaled || true

# Use dpkg -i to avoid privilege-dropping metadata read errors in user directories, then fix deps
dpkg -i "$TMP_DIR/$DEB_FILE"
if command -v apt >/dev/null 2>&1; then
    apt install -f -y
fi

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
if [ -f "$HOME/bin/tailscale" ] || [ -f "$HOME/bin/tailscaled" ]; then
    echo "-> Removing stale binaries from $HOME/bin to avoid PATH conflict..."
    rm -f "$HOME/bin/tailscale" "$HOME/bin/tailscaled" "$HOME/bin/tailscaled-start" 2>/dev/null || true
fi
if command -v termux-fix-shebang >/dev/null 2>&1; then
    echo "-> Fixing script shebangs for Termux..."
    termux-fix-shebang "$PREFIX/bin/tailscaled-start" \
                       "$PREFIX/bin/tailscaled-stop" \
                       "$PREFIX/bin/tailscaled-log" \
                       "$PREFIX/bin/tailscale-cli" \
                       "$PREFIX/bin/tailscale-test" \
                       "$PREFIX/bin/tailscale-update" \
                       "$PREFIX/var/service/tailscaled/run" 2>/dev/null || true
fi

if command -v sv-enable >/dev/null 2>&1; then
    echo "-> Enabling and starting tailscaled service via termux-services..."
    sv-enable tailscaled 2>/dev/null || true
    sv up tailscaled 2>/dev/null || true
fi

echo "============================================="
echo "Installation Complete!"
echo "Daemon is starting/running. To authenticate, run:"
echo "  tailscale-cli up"
echo "============================================="
