#!/data/data/com.termux/files/usr/bin/env bash
# Tailscale Termux Remote Installer
# Automates downloading and installing the architecture-specific deb package.
set -euo pipefail

echo "Tailscale Termux Remote Installer"
echo "=============================="

# Which Termux variant is this -- the dpkg one or the pacman one (issue #9)?
#
# NOT `command -v dpkg`: a pacman-based Termux can have dpkg installed as an
# ordinary package, and answering "deb" there unpacks a .deb over a system
# pacman owns, leaving a package that dpkg cannot configure because it sees
# none of its dependencies. Termux itself knows the answer; ask it.
detect_pkg_format() {
    local m="${TERMUX_APP_PACKAGE_MANAGER:-}"
    if [ -z "$m" ] && command -v termux-info >/dev/null 2>&1; then
        m=$(termux-info 2>/dev/null | sed -n 's/^TERMUX_APP_PACKAGE_MANAGER=//p' | head -n1)
    fi
    case "$m" in
        pacman) printf 'pacman'; return 0 ;;
        apt|dpkg|debian) printf 'deb'; return 0 ;;
    esac
    # Older Termux exposes the package format rather than the manager.
    case "${TERMUX_MAIN_PACKAGE_FORMAT:-}" in
        pacman) printf 'pacman'; return 0 ;;
        debian) printf 'deb'; return 0 ;;
    esac
    # Last resort. A pacman database that actually has packages in it is
    # decisive; dpkg merely being present is not.
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
echo "[*] Package manager: $PKG_FORMAT"

echo "[*] Checking requirements..."
REQUIREMENTS=(
    "curl:curl"
    "wget:wget"
    "grep:grep"
    # The package depends on termux-services. Without it here, the install
    # leaves an unconfigured package behind.
    "sv:termux-services"
    "sha256sum:coreutils"
)
if [ "$PKG_FORMAT" = "deb" ]; then
    REQUIREMENTS+=("zstd:zstd")
fi

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

# Convert LATEST_TAG to a package version (e.g. v1.100.0-3 -> 1.100.0.3)
DEB_VERSION=$(echo "$LATEST_TAG" | sed 's/^v//' | tr '-' '.')
if [ "$PKG_FORMAT" = "deb" ]; then
    DEB_FILE="tailscale-termux_${DEB_VERSION}_${ARCH}.deb"
else
    DEB_FILE="tailscale-termux-${DEB_VERSION}-1-${ARCH}.pkg.tar.xz"
fi
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

# Verify against the checksums published with the release. This is what makes
# publishing SHA256SUMS worth anything; the download itself is a plain fetch.
echo " -> Verifying checksum..."
EXPECTED_SHA=$(curl -fsSL "https://github.com/$REPO/releases/download/$LATEST_TAG/SHA256SUMS" 2>/dev/null \
    | awk -v f="$DEB_FILE" '{ n = $2; sub(/^\.\//, "", n); if (n == f) print $1 }' | head -n1 || true)
if [ -n "$EXPECTED_SHA" ]; then
    ACTUAL_SHA=$(sha256sum "$DOWNLOAD_DIR/$DEB_FILE" | cut -d' ' -f1)
    if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
        rm -f "$DOWNLOAD_DIR/$DEB_FILE"
        echo "Error: checksum mismatch for $DEB_FILE."
        echo "       expected: $EXPECTED_SHA"
        echo "       actual:   $ACTUAL_SHA"
        echo "       Refusing to install. Report this if it persists."
        exit 1
    fi
    echo "    OK ($ACTUAL_SHA)"
else
    # Releases published before SHA256SUMS existed have nothing to check.
    echo "    No SHA256SUMS published for $LATEST_TAG; skipping verification."
fi

# Additionally verify the GPG signature, but only if the signing key is already
# in this user's keyring -- importing it automatically would defeat the point.
#
# The .sig is fetched OUTSIDE $DOWNLOAD_DIR on purpose: a signature sitting
# next to the package makes pacman verify it against its own, separate
# keyring, which would break the install for everyone who has not imported the
# key there.
SIGNING_KEY_FPR="2D5133D5E2C7C8E7BE2D0CBB6EAA7CF6CEFB203E"
case "$DEB_FILE" in
    *.pkg.tar.xz)
        if command -v gpg >/dev/null 2>&1 && gpg --list-keys "$SIGNING_KEY_FPR" >/dev/null 2>&1; then
            SIG_TMP="$(mktemp -d)"
            if curl -fsSL "$DEB_URL.sig" -o "$SIG_TMP/pkg.sig" 2>/dev/null; then
                if gpg --verify "$SIG_TMP/pkg.sig" "$DOWNLOAD_DIR/$DEB_FILE" >/dev/null 2>&1; then
                    echo " -> GPG signature OK (${SIGNING_KEY_FPR: -16})"
                else
                    rm -rf "$SIG_TMP"
                    echo "Error: GPG signature does not verify for $DEB_FILE."
                    echo "       Refusing to install."
                    exit 1
                fi
            fi
            rm -rf "$SIG_TMP"
        fi
        ;;
esac

echo "[3/3] Installing package..."
# Stop the service first. A bare `pkill -f tailscaled` matches this project's
# own `runsv tailscaled`, `svlogd` and `tail -f ...tailscaled.log` processes,
# and killing runsv just makes runit restart the daemon a second later --
# in the middle of the install.
if command -v sv >/dev/null 2>&1 && [ -d "$PREFIX/var/service/tailscaled" ]; then
    sv down tailscaled 2>/dev/null || true
fi
pkill -f -- "--statedir=$HOME/.tailscale" 2>/dev/null || true

if [ "$PKG_FORMAT" = "deb" ]; then
    # dpkg -i avoids privilege-dropping metadata read errors in user
    # directories. It exits 1 when a dependency is unmet, having unpacked but
    # not configured the package -- `|| true` lets `apt install -f` repair it.
    dpkg -i "$DOWNLOAD_DIR/$DEB_FILE" || true
    if command -v apt >/dev/null 2>&1; then
        apt install -f -y
    fi
    # Confirm the package really is configured, rather than trusting the banner.
    if ! dpkg-query -W -f='${Status}' tailscale-termux 2>/dev/null | grep -q "install ok installed"; then
        echo "Error: the package was unpacked but not configured."
        echo "       The package is kept at: $DOWNLOAD_DIR/$DEB_FILE"
        echo "       Try: apt install -f -y && dpkg -i '$DOWNLOAD_DIR/$DEB_FILE'"
        exit 1
    fi
else
    pacman -U --noconfirm "$DOWNLOAD_DIR/$DEB_FILE" || true
    if ! pacman -Q tailscale-termux >/dev/null 2>&1; then
        echo "Error: pacman did not install the package."
        echo "       The package is kept at: $DOWNLOAD_DIR/$DEB_FILE"
        echo "       Try: pacman -U '$DOWNLOAD_DIR/$DEB_FILE'"
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

echo "============================================="
echo "Installation Complete!"
echo "Daemon is starting/running. To authenticate, run:"
echo "  tailscale-cli up"
echo ""
echo "The SOCKS5 proxy requires a password. See it with:"
echo "  tailscale-socks5"
echo "============================================="
