#!/usr/bin/env bash
# Tailscale Termux CLI Builder
# Optimized for Android 11+ with ifconfig-based netmon patch.
# Credits: Tailscale Team, asutorufa/tailscale, and Gemini CLI AI Agent.
set -eu

echo "Tailscale Termux CLI Builder"
echo "=============================="

# 1. Check for Go
if ! command -v go >/dev/null 2>&1; then
    echo "Error: Go is not installed. Please install it with 'pkg install golang' in Termux."
    exit 1
fi

# 2. Determine latest stable Tailscale version
if [ -z "${TS_VERSION:-}" ]; then
    echo "-> Fetching latest stable Tailscale version..."
    TS_VERSION=$(git ls-remote --tags --sort="v:refname" https://github.com/tailscale/tailscale.git | grep -v 'pre\|beta\|rc\|{}$' | tail -n1 | sed 's/.*\///')
    if [ -z "$TS_VERSION" ]; then
        echo "Error: Could not find latest Tailscale tag. Falling back to v1.96.5"
        TS_VERSION="v1.96.5"
    fi
fi

# Clean TS_VERSION for downloading source (e.g., convert v1.96.5-3 back to v1.96.5)
# This handles cases where TS_VERSION comes from our repository's tag.
DOWNLOAD_VERSION=$(echo "$TS_VERSION" | sed -E 's/(-[0-9]+)$//')
echo "-> Tailscale build version: $TS_VERSION"
echo "-> Tailscale source version to download: $DOWNLOAD_VERSION"

WORKDIR="$(pwd)"
SRC_DIR="$WORKDIR/tailscale_src"
PATCH_DIR="$WORKDIR/patches"
OUT_DIR="$WORKDIR/bin"

mkdir -p "$OUT_DIR"

# 3. Downloading source
echo "[1/3] Downloading Tailscale source ($DOWNLOAD_VERSION)..."
if [ ! -d "$SRC_DIR" ]; then
    if ! wget -qO- "https://github.com/tailscale/tailscale/archive/refs/tags/${DOWNLOAD_VERSION}.tar.gz" | tar -xz; then
        echo "Error: Failed to download or extract Tailscale source for version $DOWNLOAD_VERSION"
        exit 1
    fi
    mv tailscale-${DOWNLOAD_VERSION#v} "$SRC_DIR"
else
    echo "-> Source already exists. Skipping download."
fi

# 4. Applying patch
echo "[2/3] Applying netmon patch (ifconfig parser)..."
cp "$PATCH_DIR/fix_android_netmon.go" "$SRC_DIR/cmd/tailscaled/"
# Apply DNS manager patch
cd "$SRC_DIR"

# Ensure anet is available for the build
go get github.com/wlynxg/anet@v0.0.5
go mod tidy

# 5. Compiling
echo "[3/3] Compiling binaries..."
# ts_no_clipboard & ts_omit_taildrop: fix crashes/panics in Termux environment
TAGS="ts_no_clipboard,ts_omit_taildrop,ts_omit_systray,ts_omit_kube,ts_omit_aws,ts_omit_bird,ts_omit_desktop_sessions,ts_omit_networkmanager,ts_omit_sdnotify"

export GOOS=android
export GOARCH=arm64
export CGO_ENABLED=0

# Use -buildmode=pie for better Android compatibility
echo "-> Building tailscaled..."
go build -trimpath -buildmode=pie -tags "$TAGS" -ldflags="-s -w -checklinkname=0" -o "$OUT_DIR/tailscaled" ./cmd/tailscaled

echo "-> Building tailscale CLI..."
go build -trimpath -buildmode=pie -tags "$TAGS" -ldflags="-s -w -checklinkname=0" -o "$OUT_DIR/tailscale" ./cmd/tailscale

cd "$WORKDIR"
echo "Build complete! Binaries are in the 'bin' directory."
