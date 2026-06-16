#!/usr/bin/env bash
# Tailscale Termux CLI Builder
# Optimized for Android 11+ with ifconfig-based netmon patch and duplicate os.Args workaround.
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

# Clean TS_VERSION for downloading source
DOWNLOAD_VERSION=$(echo "$TS_VERSION" | sed -E 's/(-[0-9]+)$//')
echo "-> Tailscale build version: $TS_VERSION"
echo "-> Tailscale source version to download: $DOWNLOAD_VERSION"

WORKDIR="$(pwd)"
SRC_DIR="$WORKDIR/tailscale_src"
PATCH_DIR="$WORKDIR/patches"
OUT_DIR="$WORKDIR/bin"

# Determine target architecture(s)
TARGET_ARCH="${1:-}"
if [ -z "$TARGET_ARCH" ]; then
    # Detect host architecture
    HOST_ARCH=$(go env GOARCH)
    case "$HOST_ARCH" in
        arm64) TARGET_ARCH="aarch64" ;;
        arm)   TARGET_ARCH="arm"     ;;
        386)   TARGET_ARCH="i686"    ;;
        amd64) TARGET_ARCH="x86_64"  ;;
        *)
            echo "Warning: Unknown host architecture '$HOST_ARCH'. Defaulting to aarch64."
            TARGET_ARCH="aarch64"
            ;;
    esac
fi

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

# 4. Applying patches
echo "[2/3] Applying netmon and argument patches..."
cp "$PATCH_DIR/fix_android_netmon.go" "$SRC_DIR/cmd/tailscaled/"
cp "$PATCH_DIR/fix_args_android.go" "$SRC_DIR/cmd/tailscaled/"
cp "$PATCH_DIR/fix_args_android.go" "$SRC_DIR/cmd/tailscale/"

echo "-> Enabling cert endpoint on Android..."
# Prevent duplicate replacements if build script is run multiple times
if ! grep -q "localapi" "$SRC_DIR/ipn/localapi/cert.go" 2>/dev/null; then
    : # Already processed or files don't have it
fi
sed 's/!android && //g' "$SRC_DIR/ipn/localapi/cert.go" > "$SRC_DIR/ipn/localapi/cert.go.tmp" && mv "$SRC_DIR/ipn/localapi/cert.go.tmp" "$SRC_DIR/ipn/localapi/cert.go"
sed 's/ || android//g' "$SRC_DIR/ipn/localapi/disabled_stubs.go" > "$SRC_DIR/ipn/localapi/disabled_stubs.go.tmp" && mv "$SRC_DIR/ipn/localapi/disabled_stubs.go.tmp" "$SRC_DIR/ipn/localapi/disabled_stubs.go"

# Apply DNS manager patch / modules sync
cd "$SRC_DIR"

# Ensure anet is available for the build
go get github.com/wlynxg/anet@v0.0.5
go mod tidy

# 5. Compiling
echo "[3/3] Compiling binaries..."
TAGS="ts_no_clipboard,ts_omit_taildrop,ts_omit_systray,ts_omit_kube,ts_omit_aws,ts_omit_bird,ts_omit_desktop_sessions,ts_omit_networkmanager,ts_omit_sdnotify,ts_omit_ssh"

build_for_arch() {
    local arch="$1"
    local goarch=""
    local goarm=""
    local goos="linux"
    local build_mode_arg="-buildmode=pie"

    case "$arch" in
        aarch64)
            goarch="arm64"
            goos="android"
            ;;
        arm)
            goarch="arm"
            goarm="7"
            goos="linux"
            build_mode_arg=""
            ;;
        i686)
            goarch="386"
            goos="linux"
            build_mode_arg=""
            ;;
        x86_64)
            goarch="amd64"
            goos="linux"
            ;;
        *)
            echo "Error: Unknown target architecture '$arch'"
            return 1
            ;;
    esac

    echo "-> Compiling for $arch (GOARCH=$goarch, GOOS=$goos)..."
    local arch_out_dir="$OUT_DIR/$arch"
    mkdir -p "$arch_out_dir"

    export GOOS="$goos"
    export GOARCH="$goarch"
    export CGO_ENABLED=0
    if [ -n "$goarm" ]; then
        export GOARM="$goarm"
    else
        unset GOARM
    fi

    # Assemble build arguments
    local build_args=("-trimpath" "-tags" "$TAGS" "-ldflags=-s -w -checklinkname=0")
    if [ -n "$build_mode_arg" ]; then
        build_args+=("$build_mode_arg")
    fi

    # Compile tailscale CLI
    if [ -d "./cmd/scale" ]; then
        go build "${build_args[@]}" -o "$arch_out_dir/tailscale" ./cmd/scale
    else
        go build "${build_args[@]}" -o "$arch_out_dir/tailscale" ./cmd/tailscale
    fi

    # Compile tailscaled daemon
    go build "${build_args[@]}" -o "$arch_out_dir/tailscaled" ./cmd/tailscaled

    # Copy to root bin folder with architecture suffixes for release compatibility
    cp "$arch_out_dir/tailscale" "$OUT_DIR/tailscale-$arch"
    cp "$arch_out_dir/tailscaled" "$OUT_DIR/tailscaled-$arch"
}

if [ "$TARGET_ARCH" = "all" ]; then
    for arch in aarch64 arm i686 x86_64; do
        build_for_arch "$arch" &
    done
    wait
else
    build_for_arch "$TARGET_ARCH"
fi

cd "$WORKDIR"
echo "Build complete! Binaries are in the '$OUT_DIR' directory."
