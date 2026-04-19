#!/usr/bin/env bash
set -eu

echo "Tailscale Termux CLI Builder"
echo "=============================="

# Default Tailscale version
TS_VERSION="${TS_VERSION:-v1.96.5}"
WORKDIR="$(pwd)"
SRC_DIR="$WORKDIR/tailscale_src"
PATCH_DIR="$WORKDIR/patches"
OUT_DIR="$WORKDIR/bin"

mkdir -p "$OUT_DIR"

echo "[1/3] Downloading Tailscale source ($TS_VERSION)..."
if [ ! -d "$SRC_DIR" ]; then
    wget -qO- "https://github.com/tailscale/tailscale/archive/refs/tags/${TS_VERSION}.tar.gz" | tar -xz
    mv tailscale-${TS_VERSION#v} "$SRC_DIR"
else
    echo "-> Source already exists. Skipping download."
fi

echo "[2/3] Applying Android 11+ netmon patch (ifconfig parser)..."
cp "$PATCH_DIR/fix_android_netmon.go" "$SRC_DIR/cmd/tailscaled/"

cd "$SRC_DIR"
go mod tidy

echo "[3/3] Compiling binaries..."
# Removed extreme tags, kept a reasonable subset to ensure CLI functionality remains intact while stripping heavy UI/desktop dependencies.
TAGS="ts_omit_systray,ts_omit_kube,ts_omit_aws,ts_omit_bird,ts_omit_desktop_sessions,ts_omit_networkmanager,ts_omit_sdnotify"

export GOOS=android
export GOARCH=arm64
export CGO_ENABLED=0

echo "-> Compiling tailscaled..."
go build -trimpath -tags "$TAGS" -ldflags="-s -w -checklinkname=0" -o "$OUT_DIR/tailscaled-termux" ./cmd/tailscaled

echo "-> Compiling tailscale CLI..."
go build -trimpath -tags "$TAGS" -ldflags="-s -w -checklinkname=0" -o "$OUT_DIR/tailscale-termux" ./cmd/tailscale

cd "$WORKDIR"
echo "✅ Build complete! Binaries are located in the 'bin' directory."
