#!/data/data/com.termux/files/usr/bin/env bash
# Tailscale Termux Local Builder & Installer
# Detects host architecture, compiles binaries, generates completions/services, packages them as a .deb, and installs it.
set -euo pipefail

echo "Tailscale Termux Local Builder & Installer"
echo "========================================="

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# Which Termux variant is this -- the dpkg one or the pacman one (issue #9)?
# Duplicated from remote-install.sh on purpose: that one is run through
# `curl | bash` and has nothing to source.
#
# NOT `command -v dpkg`: a pacman-based Termux can have dpkg installed as an
# ordinary package, and answering "deb" there unpacks a .deb over a system
# pacman owns.
detect_pkg_format() {
    local m="${TERMUX_APP_PACKAGE_MANAGER:-}"
    if [ -z "$m" ] && command -v termux-info >/dev/null 2>&1; then
        m=$(termux-info 2>/dev/null | sed -n 's/^TERMUX_APP_PACKAGE_MANAGER=//p' | head -n1)
    fi
    case "$m" in
        pacman) printf 'pacman'; return 0 ;;
        apt|dpkg|debian) printf 'deb'; return 0 ;;
    esac
    case "${TERMUX_MAIN_PACKAGE_FORMAT:-}" in
        pacman) printf 'pacman'; return 0 ;;
        debian) printf 'deb'; return 0 ;;
    esac
    if command -v pacman >/dev/null 2>&1 && pacman -Qq >/dev/null 2>&1; then
        printf 'pacman'; return 0
    fi
    if command -v dpkg >/dev/null 2>&1; then
        printf 'deb'; return 0
    fi
    return 1
}

PKG_FORMAT=$(detect_pkg_format || true)
if [ -z "$PKG_FORMAT" ]; then
    echo "Error: could not tell whether this Termux uses dpkg or pacman."
    echo "       Check: termux-info | grep TERMUX_APP_PACKAGE_MANAGER"
    exit 1
fi
echo "-> Package manager: $PKG_FORMAT"

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
        *)
            # Defaulting to aarch64 here just buys a long build followed by an
            # opaque dpkg architecture error.
            echo "Error: Unsupported Go architecture '$HOST_ARCH'."
            echo "       Supported: arm64, arm, 386, amd64."
            exit 1
            ;;
    esac
fi

# 2. Build the deb package.
# Pin the version here so we can name the resulting file exactly, instead of
# globbing dist/ and hoping.
if [ -z "${TS_VERSION:-}" ]; then
    TS_VERSION=$(git describe --tags --always 2>/dev/null || echo "1.100.0")
fi
export TS_VERSION
DEB_VERSION=$(echo "$TS_VERSION" | sed 's/^v//' | tr '-' '.')

echo "-> Building package for $TARGET_ARCH (version $DEB_VERSION)..."
chmod +x ./build_deb.sh ./build.sh
./build_deb.sh "$TARGET_ARCH"

# 3. Find the built package for this packaging system
if [ "$PKG_FORMAT" = "deb" ]; then
    PKG_GLOB="tailscale-termux_*_${TARGET_ARCH}.deb"
    DEB_FILE="dist/tailscale-termux_${DEB_VERSION}_${TARGET_ARCH}.deb"
else
    PKG_GLOB="tailscale-termux-*-${TARGET_ARCH}.pkg.tar.xz"
    DEB_FILE="dist/tailscale-termux-${DEB_VERSION}-1-${TARGET_ARCH}.pkg.tar.xz"
fi
if [ ! -f "$DEB_FILE" ]; then
    # Fall back to the newest matching package rather than `ls | head -n 1`,
    # which sorts lexicographically and so picks the *oldest* build
    # ("...1.100.0.1" sorts before "...1.100.0.9").
    DEB_FILE=$(find dist -maxdepth 1 -name "$PKG_GLOB" -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -n1 | cut -d' ' -f2-)
fi
if [ -z "$DEB_FILE" ] || [ ! -f "$DEB_FILE" ]; then
    echo "Error: no $PKG_FORMAT package for $TARGET_ARCH found in dist/"
    exit 1
fi

# 4. Install via dpkg + apt
echo "-> Installing package: $DEB_FILE..."
# Stop the service properly. A bare `pkill -f tailscaled` also matches this
# project's own `runsv tailscaled`, `svlogd` and `tail -f ...tailscaled.log`,
# and killing runsv only makes runit restart the daemon mid-install.
if command -v sv >/dev/null 2>&1 && [ -d "$PREFIX/var/service/tailscaled" ]; then
    sv down tailscaled 2>/dev/null || true
fi
pkill -f -- "--statedir=$HOME/.tailscale" 2>/dev/null || true

if [ "$PKG_FORMAT" = "deb" ]; then
    # dpkg -i exits 1 on an unmet dependency after unpacking but not
    # configuring; `|| true` lets `apt install -f` below actually repair it.
    dpkg -i "$DEB_FILE" || true
    if command -v apt >/dev/null 2>&1; then
        echo "-> Checking/fixing dependencies..."
        apt install -f -y
    fi
    if ! dpkg-query -W -f='${Status}' tailscale-termux 2>/dev/null | grep -q "install ok installed"; then
        echo "Error: the package was unpacked but not configured."
        echo "       Try: apt install -f -y && dpkg -i '$DEB_FILE'"
        exit 1
    fi
else
    pacman -U --noconfirm "$DEB_FILE" || true
    if ! pacman -Q tailscale-termux >/dev/null 2>&1; then
        echo "Error: pacman did not install the package."
        echo "       Try: pacman -U '$DEB_FILE'"
        exit 1
    fi
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

echo "========================================="
echo "Local Installation Complete!"
echo "Daemon is starting/running. To authenticate, run:"
echo "  tailscale-cli up"
echo ""
echo "The SOCKS5 proxy requires a password. See it with:"
echo "  tailscale-socks5"
echo "========================================="
