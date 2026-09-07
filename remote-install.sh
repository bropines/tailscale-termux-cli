#!/data/data/com.termux/files/usr/bin/env bash
# Tailscale Termux Remote Installer
# Automates downloading and installing the architecture-specific deb package.
set -euo pipefail

echo "Tailscale Termux Remote Installer"
echo "=============================="

echo "[*] Checking requirements..."
REQUIREMENTS=(
    "curl:curl"
    "wget:wget"
    "grep:grep"
    "dpkg:dpkg"
    "zstd:zstd"
    # The package declares Depends: termux-services. Without it here, dpkg -i
    # refuses to configure the package and the install ends half-done.
    "sv:termux-services"
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
    # shellcheck disable=SC2086
    pkg install -y $MISSING_PKGS
else
    echo " -> All installer dependencies are present."
fi

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
REPO="bropines/tailscale-termux-cli"

echo "[1/3] Fetching latest release info..."
# `|| true` is load-bearing: under `set -e` a failing grep (GitHub rate-limits
# unauthenticated API calls to 60/hour per IP, which carrier NAT reaches easily)
# aborts the script on this assignment, making the check below unreachable.
LATEST_TAG=$(curl -fsS "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | grep -Po '"tag_name": "\K.*?(?=")' || true)

if [ -z "$LATEST_TAG" ]; then
    echo "Error: could not fetch the latest release."
    echo "       GitHub may be rate-limiting this IP, or there is no network."
    echo "       Try again later, or download the .deb manually from:"
    echo "       https://github.com/$REPO/releases/latest"
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
# Keep the download outside the trap's reach so a failed install can be retried
# by hand instead of leaving a half-configured package and no .deb to fix it with.
DOWNLOAD_DIR="$HOME/.cache/tailscale-termux"
mkdir -p "$DOWNLOAD_DIR"

if ! wget -q --show-progress -O "$DOWNLOAD_DIR/$DEB_FILE" "$DEB_URL"; then
    rm -f "$DOWNLOAD_DIR/$DEB_FILE"
    echo "Error: failed to download $DEB_URL"
    exit 1
fi

echo "[3/3] Installing package via dpkg..."
# Stop the service first. A bare `pkill -f tailscaled` matches this project's
# own `runsv tailscaled`, `svlogd` and `tail -f ...tailscaled.log` processes,
# and killing runsv just makes runit restart the daemon a second later --
# in the middle of dpkg -i.
if command -v sv >/dev/null 2>&1 && [ -d "$PREFIX/var/service/tailscaled" ]; then
    sv down tailscaled 2>/dev/null || true
fi
pkill -f -- "--statedir=$HOME/.tailscale" 2>/dev/null || true

# dpkg -i avoids privilege-dropping metadata read errors in user directories.
# It exits 1 when a dependency is unmet, having unpacked but not configured the
# package -- `|| true` lets the `apt install -f` below actually do its job.
dpkg -i "$DOWNLOAD_DIR/$DEB_FILE" || true
if command -v apt >/dev/null 2>&1; then
    apt install -f -y
fi

# Confirm the package really is configured, rather than trusting the banner.
if ! dpkg-query -W -f='${Status}' tailscale-termux 2>/dev/null | grep -q "install ok installed"; then
    echo "Error: the package was unpacked but not configured."
    echo "       The .deb is kept at: $DOWNLOAD_DIR/$DEB_FILE"
    echo "       Try: apt install -f -y && dpkg -i '$DOWNLOAD_DIR/$DEB_FILE'"
    exit 1
fi

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
                       "$PREFIX/bin/tailscale-socks5" \
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
echo ""
echo "The SOCKS5 proxy requires a password. See it with:"
echo "  tailscale-socks5"
echo "============================================="
