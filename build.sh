#!/usr/bin/env bash
# Tailscale Termux CLI Builder
# Optimized for Android 11+ with ifconfig-based netmon patch and duplicate os.Args workaround.
# Credits: Tailscale Team, asutorufa/tailscale, and Gemini CLI AI Agent.
set -euo pipefail

echo "Tailscale Termux CLI Builder"
echo "=============================="

# 1. Check for build tools
MISSING=""
for tool in go git wget tar sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
    echo "Error: missing required tools:$MISSING"
    echo "Install them in Termux with 'pkg install golang git wget tar coreutils'."
    exit 1
fi

# 2. Determine latest stable Tailscale version
if [ -z "${TS_VERSION:-}" ]; then
    echo "-> Fetching latest stable Tailscale version..."
    # pipefail is on, so a failing git ls-remote is caught here rather than
    # silently yielding an empty string and falling through to the fallback.
    TS_VERSION=$(git ls-remote --tags --sort="v:refname" https://github.com/tailscale/tailscale.git 2>/dev/null | grep -v 'pre\|beta\|rc\|{}$' | tail -n1 | sed 's/.*\///') || TS_VERSION=""
    if [ -z "$TS_VERSION" ]; then
        echo "Error: Could not find latest Tailscale tag (no network?)."
        echo "       Set TS_VERSION explicitly, e.g. TS_VERSION=v1.100.0 ./build.sh"
        exit 1
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
SRC_STAMP="$SRC_DIR/.ts_version"
CHECKSUM_DIR="$WORKDIR/checksums"

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
# The cache is keyed on the version it was populated with. Without this a
# `git pull` + rebuild happily reuses an old tree and stamps the new version
# onto a stale binary, so `tailscale-update` then reports you are current.
if [ -d "$SRC_DIR" ]; then
    CACHED_VERSION=$(cat "$SRC_STAMP" 2>/dev/null || echo "unknown")
    if [ "$CACHED_VERSION" != "$DOWNLOAD_VERSION" ]; then
        echo "-> Cached source is $CACHED_VERSION, need $DOWNLOAD_VERSION. Removing."
        rm -rf "$SRC_DIR"
    else
        echo "-> Source $CACHED_VERSION already present. Skipping download."
    fi
fi

if [ ! -d "$SRC_DIR" ]; then
    # Download to a file rather than piping straight into tar, so the archive
    # can be checksummed before any of its contents are unpacked, compiled and
    # (for shell completions) executed on this machine.
    TARBALL="$WORKDIR/.tailscale-${DOWNLOAD_VERSION}.tar.gz"
    if ! wget -q -O "$TARBALL" "https://github.com/tailscale/tailscale/archive/refs/tags/${DOWNLOAD_VERSION}.tar.gz"; then
        rm -f "$TARBALL"
        echo "Error: Failed to download Tailscale source for version $DOWNLOAD_VERSION"
        exit 1
    fi

    ACTUAL_SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)
    EXPECTED_FILE="$CHECKSUM_DIR/${DOWNLOAD_VERSION}.sha256"
    if [ -f "$EXPECTED_FILE" ]; then
        EXPECTED_SHA=$(cut -d' ' -f1 < "$EXPECTED_FILE")
        if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
            rm -f "$TARBALL"
            echo "Error: checksum mismatch for Tailscale $DOWNLOAD_VERSION."
            echo "       expected: $EXPECTED_SHA"
            echo "       actual:   $ACTUAL_SHA"
            echo "       Refusing to build. A release tag should never change contents."
            exit 1
        fi
        echo "-> Source checksum verified against $EXPECTED_FILE"
    elif [ -n "${TS_REQUIRE_CHECKSUM:-}" ]; then
        rm -f "$TARBALL"
        echo "Error: no pinned checksum for $DOWNLOAD_VERSION and TS_REQUIRE_CHECKSUM is set."
        echo "       Record it with: echo '$ACTUAL_SHA  tailscale-$DOWNLOAD_VERSION.tar.gz' > $EXPECTED_FILE"
        exit 1
    else
        mkdir -p "$CHECKSUM_DIR"
        echo "$ACTUAL_SHA  tailscale-${DOWNLOAD_VERSION}.tar.gz" > "$EXPECTED_FILE"
        echo "-> No pinned checksum for $DOWNLOAD_VERSION; recorded $ACTUAL_SHA"
        echo "   Commit $EXPECTED_FILE so later builds verify against it."
    fi

    if ! tar -xzf "$TARBALL" -C "$WORKDIR"; then
        rm -f "$TARBALL"
        echo "Error: Failed to extract Tailscale source for version $DOWNLOAD_VERSION"
        exit 1
    fi
    rm -f "$TARBALL"
    mv "$WORKDIR/tailscale-${DOWNLOAD_VERSION#v}" "$SRC_DIR"
    echo "$DOWNLOAD_VERSION" > "$SRC_STAMP"
fi

# 4. Applying patches
echo "[2/3] Applying netmon, argument and SOCKS5 auth patches..."
cp "$PATCH_DIR/fix_android_netmon.go" "$SRC_DIR/cmd/tailscaled/"
cp "$PATCH_DIR/fix_args_android.go" "$SRC_DIR/cmd/tailscaled/"
cp "$PATCH_DIR/fix_args_android.go" "$SRC_DIR/cmd/tailscale/"
cp "$PATCH_DIR/fix_socks5_auth.go" "$SRC_DIR/cmd/tailscaled/"

echo "-> Enabling cert endpoint on Android..."
# Both substitutions are idempotent: after the first pass there is no
# "!android && " or " || android" left to match.
sed 's/!android && //g' "$SRC_DIR/ipn/localapi/cert.go" > "$SRC_DIR/ipn/localapi/cert.go.tmp" && mv "$SRC_DIR/ipn/localapi/cert.go.tmp" "$SRC_DIR/ipn/localapi/cert.go"
sed 's/ || android//g' "$SRC_DIR/ipn/localapi/disabled_stubs.go" > "$SRC_DIR/ipn/localapi/disabled_stubs.go.tmp" && mv "$SRC_DIR/ipn/localapi/disabled_stubs.go.tmp" "$SRC_DIR/ipn/localapi/disabled_stubs.go"

# Wire the SOCKS5 credentials into the proxy server. Upstream's socks5.Server
# already has Username/Password fields; cmd/tailscaled simply never sets them,
# which is why --socks5-server has always listened unauthenticated.
#
# A failure to apply is fatal on purpose: silently shipping an open proxy is
# exactly the outcome this guards against.
echo "-> Wiring SOCKS5 authentication into cmd/tailscaled/proxy.go..."
PROXY_GO="$SRC_DIR/cmd/tailscaled/proxy.go"
if grep -q "termuxSocks5User()" "$PROXY_GO"; then
    echo "   already wired, skipping."
elif grep -q "Dialer: dialer.UserDial," "$PROXY_GO"; then
    sed 's|Dialer: dialer.UserDial,|Dialer:   dialer.UserDial,\n\t\t\t\tUsername: termuxSocks5User(),\n\t\t\t\tPassword: termuxSocks5Pass(),|' \
        "$PROXY_GO" > "$PROXY_GO.tmp" && mv "$PROXY_GO.tmp" "$PROXY_GO"
    grep -q "termuxSocks5User()" "$PROXY_GO" || { echo "Error: SOCKS5 auth injection did not take effect."; exit 1; }
    echo "   done."
else
    echo "Error: could not find the socks5.Server literal in $PROXY_GO."
    echo "       Upstream changed cmd/tailscaled/proxy.go; update this patch step"
    echo "       before releasing, or the proxy ships without authentication."
    exit 1
fi

# Apply DNS manager patch / modules sync
cd "$SRC_DIR"

# Ensure anet is available for the build
go get github.com/wlynxg/anet@v0.0.5
go mod tidy

# 5. Compiling
echo "[3/3] Compiling binaries..."
TAGS="ts_no_clipboard,ts_omit_taildrop,ts_omit_systray,ts_omit_kube,ts_omit_aws,ts_omit_bird,ts_omit_desktop_sessions,ts_omit_networkmanager,ts_omit_sdnotify,ts_omit_ssh"

# Fail the build if a patch silently dropped out of the binary.
#
# Three of the four published architectures once shipped for months without
# the netmon patch because a build tag stopped matching -- a change that
# produces no warning anywhere. Checking the artifact itself is the only way
# to notice.
verify_patched() {
    local arch="$1" bin="$2" missing=""
    grep -aq "\[Termux\]" "$bin" || missing="$missing netmon"
    grep -aq "wlynxg/anet" "$bin" || missing="$missing anet"
    grep -aq "TS_SOCKS5_USER" "$bin" || missing="$missing socks5-auth"
    if [ -n "$missing" ]; then
        echo "Error: $arch/tailscaled is missing patches:$missing"
        echo "       Refusing to publish an unpatched binary. Check the"
        echo "       //go:build tags in patches/ against GOOS for this target."
        return 1
    fi
    echo "-> $arch: netmon, anet and SOCKS5 auth patches verified in binary."
}

# Why the two build profiles below:
#
#   GOOS=android requires external (cgo) linking on every architecture except
#   arm64 -- `go build` refuses outright with "android/amd64 requires external
#   (cgo) linking". Cross-compiling those would mean shipping an Android NDK
#   toolchain, so they are built as GOOS=linux instead.
#
#   That is only safe because the patches are tagged `android || linux`; when
#   they were tagged `android` alone, these three architectures silently
#   shipped without the netmon patch that is the whole point of this project.
#   The verify_patched check below is what keeps that from happening again.
#
#   -buildmode=pie is likewise arm64-only. With CGO_ENABLED=0 a PIE build for
#   linux/amd64 comes out as a dynamic ELF with .interp=/lib64/ld-linux-x86-64.so.2,
#   a glibc loader Android does not have, so the binary cannot start at all.
#   Without PIE the same build is a static executable that runs fine.
build_for_arch() {
    local arch="$1"
    local goarch=""
    local goarm=""
    local goos="linux"
    local build_mode_arg=""

    case "$arch" in
        aarch64)
            goarch="arm64"
            goos="android"
            build_mode_arg="-buildmode=pie"
            ;;
        arm)
            goarch="arm"
            goarm="7"
            ;;
        i686)
            goarch="386"
            ;;
        x86_64)
            goarch="amd64"
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

    verify_patched "$arch" "$arch_out_dir/tailscaled" || return 1

    # Record what these binaries were built from so build_deb.sh can tell a
    # stale cache from a current one.
    echo "$DOWNLOAD_VERSION" > "$arch_out_dir/.ts_version"

    # Copy to root bin folder with architecture suffixes for release compatibility
    cp "$arch_out_dir/tailscale" "$OUT_DIR/tailscale-$arch"
    cp "$arch_out_dir/tailscaled" "$OUT_DIR/tailscaled-$arch"
}

if [ "$TARGET_ARCH" = "all" ]; then
    ARCHES=(aarch64 arm i686 x86_64)
    PIDS=()
    for arch in "${ARCHES[@]}"; do
        build_for_arch "$arch" &
        PIDS+=("$!")
    done
    # A bare `wait` always returns 0, so failures in these background jobs used
    # to be reported as "Build complete!".
    FAILED=""
    for i in "${!PIDS[@]}"; do
        if ! wait "${PIDS[$i]}"; then
            FAILED="$FAILED ${ARCHES[$i]}"
        fi
    done
    if [ -n "$FAILED" ]; then
        echo "Error: build failed for:$FAILED"
        exit 1
    fi
else
    build_for_arch "$TARGET_ARCH"
fi

cd "$WORKDIR"
echo "Build complete! Binaries are in the '$OUT_DIR' directory."
