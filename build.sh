#!/usr/bin/env bash
# Tailscale Termux CLI Builder
# Builds with a Go toolchain carrying Termux's standard-library patches.
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
TERMUX_PREFIX="/data/data/com.termux/files/usr"

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

# 3.5 Prepare a patched Go toolchain
#
# Vanilla Go cannot produce a working Android binary for this project, and no
# amount of patching tailscale fixes it, because both problems are in Go's own
# standard library:
#
#   * net.Interfaces() fails with "netlinkrib: permission denied" -- Android 11+
#     denies app UIDs bind(2) on netlink sockets -- so netmon.New errors out.
#   * There is no /etc/resolv.conf on Android, so the pure resolver falls back
#     to [::1]:53 and every lookup fails.
#
# Termux solves both in the Go it ships, and applies the same patches when
# cross-compiling other packages. We vendor those patches (see patches/go/) and
# do the same, which is why this project no longer carries netmon or DNS
# patches of its own. Verified on Android 16 in a real untrusted_app context:
# vanilla Go reproduces both failures, the patched toolchain reports 8
# interfaces and resolves names.
GO_VERSION="1.27.1"
GO_SHA256="63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445"
GOTOOLDIR="$WORKDIR/.gotoolchain"
GOROOT_PATCHED="$GOTOOLDIR/go"
GO_STAMP="$GOROOT_PATCHED/.termux-patched"

setup_patched_go() {
    if [ -f "$GO_STAMP" ] && [ "$(cat "$GO_STAMP")" = "$GO_VERSION" ]; then
        echo "-> Patched Go $GO_VERSION already prepared."
        return 0
    fi

    echo "-> Preparing patched Go $GO_VERSION toolchain..."
    rm -rf "$GOTOOLDIR"
    mkdir -p "$GOTOOLDIR"

    local tarball="$GOTOOLDIR/go.tar.gz"
    if ! wget -q -O "$tarball" "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"; then
        echo "Error: could not download Go $GO_VERSION."
        exit 1
    fi
    local actual
    actual=$(sha256sum "$tarball" | cut -d' ' -f1)
    if [ -n "$GO_SHA256" ] && [ "$actual" != "$GO_SHA256" ]; then
        echo "Error: Go $GO_VERSION checksum mismatch."
        echo "       expected: $GO_SHA256"
        echo "       actual:   $actual"
        exit 1
    fi
    tar -xzf "$tarball" -C "$GOTOOLDIR"
    rm -f "$tarball"

    # Termux's patches are gated on //go:build android and expect these copies
    # to exist, exactly as packages/golang/patch-script/*.sh creates them.
    ( cd "$GOROOT_PATCHED"
      cp -T src/net/conf.go src/net/conf_android.go
      cp -T src/net/dnsclient_unix.go src/net/dnsclient_android.go
      cp -T src/syscall/netlink_linux.go src/syscall/netlink_android.go
      cp -T src/net/interface_linux.go src/net/interface_android.go )

    local d
    for d in fix-hardcoded-etc-resolv-conf fix-android-netlink remove-pidfd remove-futex_time64; do
        # Fatal on failure. These patches are sensitive to the Go version, and
        # a silently unpatched toolchain produces a binary that looks fine and
        # cannot resolve a name or list an interface on a phone.
        if ! sed -e "s|@TERMUX_PREFIX@|$TERMUX_PREFIX|g" "$PATCH_DIR/go/$d.diff" \
             | ( cd "$GOROOT_PATCHED" && patch --silent -p1 ); then
            echo "Error: Go patch $d did not apply to go$GO_VERSION."
            echo "       Refresh them with ./patches/go/refresh.sh, or pin a Go"
            echo "       version they still match. Building without them yields"
            echo "       a binary that cannot resolve names or list interfaces."
            exit 1
        fi
    done

    # Prove the two that matter actually landed.
    grep -q "$TERMUX_PREFIX/etc/resolv.conf" "$GOROOT_PATCHED/src/net/dnsclient_android.go" \
        || { echo "Error: resolv.conf patch did not take effect."; exit 1; }
    grep -q 'EPERM' "$GOROOT_PATCHED/src/syscall/netlink_android.go" \
        || { echo "Error: netlink patch did not take effect."; exit 1; }

    echo "$GO_VERSION" > "$GO_STAMP"
    echo "   done."
}

# On a phone, Termux's own Go already carries exactly these patches -- and a
# linux-amd64 toolchain could not run there anyway.
if [ "$(go env GOOS 2>/dev/null)" = "android" ]; then
    ON_DEVICE=1
    echo "-> Building on Android: using Termux's Go, which already carries these patches."
else
    ON_DEVICE=0
    setup_patched_go
    export GOROOT="$GOROOT_PATCHED"
    export PATH="$GOROOT/bin:$PATH"
fi
# Without this, Go silently downloads and switches to the toolchain named in
# tailscale's go.mod, discarding every patch above.
export GOTOOLCHAIN=local
echo "-> Building with $(go version)"

# Locate the NDK C compiler for a target. Go refuses GOOS=android without
# external (cgo) linking on every architecture except arm64, so the other three
# cannot be cross-compiled without it.
ndk_cc_for() {
    local goarch="$1" triple=""
    case "$goarch" in
        arm64) triple="aarch64-linux-android" ;;
        arm)   triple="armv7a-linux-androideabi" ;;
        386)   triple="i686-linux-android" ;;
        amd64) triple="x86_64-linux-android" ;;
    esac
    local ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_ROOT:-}}}"
    if [ -z "$ndk" ] && [ -d "$HOME/android-sdk/ndk" ]; then
        ndk=$(find "$HOME/android-sdk/ndk" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -n1)
    fi
    [ -n "$ndk" ] || return 1
    # API 24 matches Termux's own minSdk.
    local cc="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/${triple}24-clang"
    [ -x "$cc" ] || return 1
    printf '%s' "$cc"
}

# 4. Applying patches
echo "[2/3] Applying hostinfo, argument and SOCKS5 auth patches..."
cp "$PATCH_DIR/fix_hostinfo_android.go" "$SRC_DIR/cmd/tailscaled/"
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

cd "$SRC_DIR"

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
    # The resolv.conf path only appears if the Go toolchain carried Termux's
    # patch, which is also what fixes net.Interfaces(). Checking the artifact
    # matters more than checking the build: a toolchain patch that silently
    # stopped applying produces a binary that looks fine and cannot resolve a
    # name or see an interface on a phone.
    grep -aq "$TERMUX_PREFIX/etc/resolv.conf" "$bin" || missing="$missing go-toolchain"
    grep -aq "\[Termux\]" "$bin" || missing="$missing hostinfo"
    grep -aq "TS_SOCKS5_USER" "$bin" || missing="$missing socks5-auth"
    if [ -n "$missing" ]; then
        echo "Error: $arch/tailscaled is missing patches:$missing"
        echo "       Refusing to publish an unpatched binary."
        return 1
    fi
    echo "-> $arch: Go toolchain, hostinfo and SOCKS5 auth patches verified in binary."
}

# Every target is GOOS=android, which is what makes Termux's standard-library
# patches (//go:build android) apply. -buildmode=pie throughout, because
# Termux builds that target API 29+ launch binaries through /system/bin/linker,
# which rejects ET_EXEC.
#
# arm64 links internally and needs no C compiler; the other three do, so they
# need the NDK. On a phone there is no cross-compiling and Termux's clang
# serves as the C compiler.
build_for_arch() {
    local arch="$1"
    local goarch=""
    local goarm=""
    local goos="android"

    case "$arch" in
        aarch64) goarch="arm64" ;;
        arm)     goarch="arm"; goarm="7" ;;
        i686)    goarch="386" ;;
        x86_64)  goarch="amd64" ;;
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
    if [ -n "$goarm" ]; then
        export GOARM="$goarm"
    else
        unset GOARM
    fi

    if [ "$ON_DEVICE" = "1" ]; then
        # Native build: Termux's clang is the C compiler, cgo on by default.
        unset CC
        export CGO_ENABLED=1
    elif [ "$goarch" = "arm64" ]; then
        export CGO_ENABLED=0
        unset CC
    else
        local cc
        if ! cc=$(ndk_cc_for "$goarch"); then
            echo "Error: no Android NDK C compiler for $arch."
            echo "       Go cannot cross-compile GOOS=android/$goarch without cgo."
            echo "       Set ANDROID_NDK_HOME, or build this architecture on a device."
            return 1
        fi
        export CC="$cc"
        export CGO_ENABLED=1
    fi

    # Assemble build arguments
    local build_args=("-trimpath" "-tags" "$TAGS" "-ldflags=-s -w -checklinkname=0" "-buildmode=pie")

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
