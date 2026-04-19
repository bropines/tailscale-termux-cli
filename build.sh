#!/usr/bin/env bash
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
echo "-> Using Tailscale version: $TS_VERSION"

WORKDIR="$(pwd)"
SRC_DIR="$WORKDIR/tailscale_src"
PATCH_DIR="$WORKDIR/patches"
OUT_DIR="$WORKDIR/bin"

mkdir -p "$OUT_DIR"

# 3. Downloading source
echo "[1/3] Downloading Tailscale source..."
if [ ! -d "$SRC_DIR" ]; then
    wget -qO- "https://github.com/tailscale/tailscale/archive/refs/tags/${TS_VERSION}.tar.gz" | tar -xz
    mv tailscale-${TS_VERSION#v} "$SRC_DIR"
else
    echo "-> Source already exists. Skipping download."
fi

# 4. Applying patch
echo "[2/3] Applying netmon patch (ifconfig parser)..."
cp "$PATCH_DIR/fix_android_netmon.go" "$SRC_DIR/cmd/tailscaled/"

cd "$SRC_DIR"
# Ensure anet is available for the build even if we use ifconfig parser (dependency safety)
go get github.com/wlynxg/anet@v0.0.5
go mod tidy

# 5. Compiling
echo "[3/3] Compiling binaries..."
TAGS="ts_omit_systray,ts_omit_kube,ts_omit_aws,ts_omit_bird,ts_omit_desktop_sessions,ts_omit_networkmanager,ts_omit_sdnotify"

export GOOS=android
export GOARCH=arm64
export CGO_ENABLED=0

echo "-> Building tailscaled..."
go build -trimpath -tags "$TAGS" -ldflags="-s -w -checklinkname=0" -o "$OUT_DIR/tailscaled" ./cmd/tailscaled

echo "-> Building tailscale CLI..."
go build -trimpath -tags "$TAGS" -ldflags="-s -w -checklinkname=0" -o "$OUT_DIR/tailscale" ./cmd/tailscale

cd "$WORKDIR"
echo "Build complete! Binaries are in the 'bin' directory."
