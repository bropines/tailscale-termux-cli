#!/usr/bin/env bash
# Tailscale Termux CLI Package Builder
set -euo pipefail

echo "Tailscale Termux Debian Package Builder"
echo "======================================="

# Determine version
if [ -z "${TS_VERSION:-}" ]; then
    # Try to find from git tag or default
    TS_VERSION=$(git describe --tags --always 2>/dev/null || echo "1.100.0")
fi
# Hand the same version down to build.sh, so the source it downloads and the
# version stamped on the package cannot disagree.
export TS_VERSION
# Clean version string for debian (replace starting 'v' if present, replace dashes with tildes)
DEB_VERSION=$(echo "$TS_VERSION" | sed 's/^v//' | tr '-' '.')
# The upstream source version these binaries must have been built from.
SRC_VERSION=$(echo "$TS_VERSION" | sed -E 's/(-[0-9]+)$//')
case "$SRC_VERSION" in
    v*) ;;
    *) SRC_VERSION="v$SRC_VERSION" ;;
esac

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

WORKDIR="$(pwd)"
DIST_DIR="$WORKDIR/dist"
BIN_DIR="$WORKDIR/bin"
SRC_DIR="$WORKDIR/tailscale_src"

# Are the cached binaries for $1 current for $SRC_VERSION?
binaries_are_current() {
    local arch="$1"
    [ -f "$BIN_DIR/$arch/tailscale" ] || return 1
    [ -f "$BIN_DIR/$arch/tailscaled" ] || return 1
    # Without this check a stale binary gets packaged under a fresh version
    # number, and tailscale-update then cheerfully reports you are up to date.
    [ "$(cat "$BIN_DIR/$arch/.ts_version" 2>/dev/null || echo unknown)" = "$SRC_VERSION" ]
}

# Emit a pacman package from the same staged payload as the .deb.
#
# Termux ships a pacman-based variant (issue #9), whose packages are a tar
# archive of the filesystem plus a .PKGINFO metadata file and an optional
# .INSTALL scriptlet, both of which must come first in the archive.
build_pacman_from_stage() {
    local pkg_dir="$1" arch="$2"
    local out="$DIST_DIR/tailscale-termux-${DEB_VERSION}-1-${arch}.pkg.tar.xz"
    local stage="$DIST_DIR/.pacman_${arch}"

    rm -rf "$stage"
    mkdir -p "$stage"
    # Same payload, minus the Debian-only control directory.
    ( cd "$pkg_dir" && tar -cf - --exclude=./DEBIAN data ) | ( cd "$stage" && tar -xf - )

    local size
    size=$(du -sb "$stage" | cut -f1)

    cat > "$stage/.PKGINFO" << PKGINFO
pkgname = tailscale-termux
pkgbase = tailscale-termux
pkgver = ${DEB_VERSION}-1
pkgdesc = Patched Tailscale CLI for Termux on Android 11+
url = https://github.com/bropines/tailscale-termux-cli
builddate = $(date +%s)
packager = bropines <https://github.com/bropines/tailscale-termux-cli>
size = $size
arch = $arch
license = BSD-3-Clause
conflict = tailscale
replaces = tailscale
depend = termux-services
depend = curl
depend = wget
depend = procps
depend = coreutils
PKGINFO

    # pacman's equivalent of postinst; both call the same on-device script.
    cat > "$stage/.INSTALL" << 'INSTALL'
post_install() {
    sh "${PREFIX:-/data/data/com.termux/files/usr}/libexec/tailscale-termux/post-install.sh" install || true
}

post_upgrade() {
    sh "${PREFIX:-/data/data/com.termux/files/usr}/libexec/tailscale-termux/post-install.sh" upgrade || true
}
INSTALL

    # .PKGINFO and .INSTALL must precede the payload in the archive.
    ( cd "$stage" && tar -cf - .PKGINFO .INSTALL data | xz -T0 -c > "$out" )
    rm -rf "$stage"
    echo "-> Pacman package created successfully: $out"
}

build_deb_for_arch() {
    local arch="$1"
    local deb_arch=""

    case "$arch" in
        aarch64) deb_arch="aarch64" ;;
        arm)     deb_arch="arm"     ;;
        i686)    deb_arch="i686"    ;;
        x86_64)  deb_arch="x86_64"  ;;
        *)
            echo "Error: Unknown architecture '$arch'"
            return 1
            ;;
    esac

    echo "-> Preparing .deb package for $arch (version: $DEB_VERSION)..."

    # Verify binaries exist and match the requested source version
    if ! binaries_are_current "$arch"; then
        echo "Binaries for $arch missing or stale. Building them first..."
        ./build.sh "$arch"
    fi

    # Define paths
    local pkg_dir="$DIST_DIR/tailscale-termux_${DEB_VERSION}_${deb_arch}"
    local usr_bin_dir="$pkg_dir/data/data/com.termux/files/usr/bin"
    local service_dir="$pkg_dir/data/data/com.termux/files/usr/var/service/tailscaled"
    local doc_dir="$pkg_dir/data/data/com.termux/files/usr/share/doc/tailscale-termux"

    # Clean previous build
    rm -rf "$pkg_dir"
    mkdir -p "$usr_bin_dir"
    mkdir -p "$service_dir/log"
    mkdir -p "$pkg_dir/DEBIAN"
    mkdir -p "$doc_dir"

    # 1. Copy main binaries
    cp "$BIN_DIR/$arch/tailscale" "$usr_bin_dir/tailscale"
    cp "$BIN_DIR/$arch/tailscaled" "$usr_bin_dir/tailscaled"
    chmod +x "$usr_bin_dir/tailscale" "$usr_bin_dir/tailscaled"

    # 2. Setup termux-services
    cp "$WORKDIR/termux-services/tailscaled/run" "$service_dir/run"
    chmod +x "$service_dir/run"

    # Create 'down' file so runit does not auto-start the service upon package installation
    touch "$service_dir/down"

    # Log service run script.
    # svlogd does not create its own log directory and exits fatally if it
    # cannot open one, which puts runsv into a restart loop.
    cat << 'EOF' > "$service_dir/log/run"
#!/data/data/com.termux/files/usr/bin/sh
LOGDIR="${PREFIX:-/data/data/com.termux/files/usr}/var/log/tailscaled"
mkdir -p "$LOGDIR"
exec svlogd -tt "$LOGDIR"
EOF
    chmod +x "$service_dir/log/run"

    # 2.5 Setup shell autocompletions
    local completions_dir="$pkg_dir/data/data/com.termux/files/usr/share"
    local bash_comp_dir="$completions_dir/bash-completion/completions"
    local zsh_comp_dir="$completions_dir/zsh/site-functions"
    local fish_comp_dir="$completions_dir/fish/vendor_completions.d"

    mkdir -p "$bash_comp_dir" "$zsh_comp_dir" "$fish_comp_dir"

    echo "-> Generating shell completions..."
    # Prefer the binary we just built. On a Termux install the target is the
    # host, so this both skips a second compile and avoids building *and*
    # running a second copy of freshly downloaded upstream code on the
    # packaging machine (which, for install.sh, is the user's phone).
    local comp_bin="$BIN_DIR/$arch/tailscale"
    local host_built=""
    if ! "$comp_bin" completion bash > "$bash_comp_dir/tailscale" 2>/dev/null || [ ! -s "$bash_comp_dir/tailscale" ]; then
        echo "   (target binary is not runnable here; building a host one)"
        (
            cd "$SRC_DIR"
            go build -o "$WORKDIR/tailscale-host-$arch" ./cmd/tailscale
        )
        comp_bin="$WORKDIR/tailscale-host-$arch"
        host_built=1
        "$comp_bin" completion bash > "$bash_comp_dir/tailscale"
    fi
    "$comp_bin" completion zsh > "$zsh_comp_dir/_tailscale"
    "$comp_bin" completion fish > "$fish_comp_dir/tailscale.fish"
    # Not `[ ... ] && rm`: a false test would return 1 and trip `set -e`.
    if [ -n "$host_built" ]; then
        rm -f "$comp_bin"
    fi

    # Register tailscale-cli shell integrations
    echo "complete -F _tailscale tailscale-cli" > "$bash_comp_dir/tailscale-cli"

    cat << 'EOF' > "$zsh_comp_dir/_tailscale-cli"
#compdef tailscale-cli
compdef tailscale-cli=tailscale
EOF

    echo "complete -c tailscale-cli -w tailscale" > "$fish_comp_dir/tailscale-cli.fish"

    # 2.6 Copyright notice.
    # Almost everything shipped here is Tailscale's BSD-3 code, whose clause 2
    # requires reproducing the notice in binary distributions.
    cp "$WORKDIR/LICENSE" "$doc_dir/copyright"
    if [ -f "$SRC_DIR/LICENSE" ]; then
        {
            echo
            echo "----------------------------------------------------------------"
            echo "The tailscale and tailscaled binaries in this package are built"
            echo "from Tailscale's source (https://github.com/tailscale/tailscale),"
            echo "distributed under the following license:"
            echo "----------------------------------------------------------------"
            echo
            cat "$SRC_DIR/LICENSE"
        } >> "$doc_dir/copyright"
    fi

    # 3. Create helper scripts in bin
    local helper_start="$usr_bin_dir/tailscaled-start"
    local helper_stop="$usr_bin_dir/tailscaled-stop"
    local helper_log="$usr_bin_dir/tailscaled-log"
    local helper_cli="$usr_bin_dir/tailscale-cli"
    local helper_test="$usr_bin_dir/tailscale-test"
    local helper_update="$usr_bin_dir/tailscale-update"
    local helper_socks="$usr_bin_dir/tailscale-socks5"

    # Shared library sourced by every helper, so the daemon is located the same
    # way everywhere instead of five slightly different pgrep patterns.
    local libexec_dir="$pkg_dir/data/data/com.termux/files/usr/libexec/tailscale-termux"
    mkdir -p "$libexec_dir"
    cat << 'EOF' > "$libexec_dir/common.sh"
# shellcheck shell=bash
# Shared helpers for the tailscale-termux scripts.

STATE_DIR="$HOME/.tailscale"
LOG_FILE="$STATE_DIR/tailscaled.log"
SOCKET="$STATE_DIR/tailscaled.sock"
ENV_FILE="$STATE_DIR/.env"
CRED_FILE="$STATE_DIR/socks5.env"
SOCKS_ADDR_FILE="$STATE_DIR/socks_addr"
BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
SVLOG_DIR="${PREFIX:-/data/data/com.termux/files/usr}/var/log/tailscaled"

# PIDs of tailscaled daemons using our state directory.
#
# Matching on the process name rather than `pgrep -f tailscaled` matters twice
# over: the old pattern matched this helper's own cmdline (so "already running"
# fired when nothing was), and it matched runsv/svlogd/tail as well.
daemon_pids() {
    local pid found=""
    for pid in $(pgrep -x tailscaled 2>/dev/null || true); do
        if [ -r "/proc/$pid/cmdline" ]; then
            if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- "--statedir=$STATE_DIR"; then
                found="$found $pid"
            fi
        else
            found="$found $pid"
        fi
    done
    printf '%s' "${found# }"
}

daemon_running() {
    [ -n "$(daemon_pids)" ]
}

# Is tailscaled managed by termux-services right now?
service_present() {
    command -v sv >/dev/null 2>&1 &&
        [ -d "${PREFIX:-/data/data/com.termux/files/usr}/var/service/tailscaled" ]
}

# The SOCKS5 address the running daemon actually listens on, read from its
# cmdline. The socks_addr file is only a fallback: it goes stale whenever the
# daemon is restarted by another path.
live_socks_addr() {
    local pid cmd
    for pid in $(daemon_pids); do
        cmd=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null || true)
        printf '%s\n' "$cmd" | sed -n 's/^--socks5-server=//p' | head -n1
        return 0
    done
    return 1
}

load_credentials() {
    if [ -f "$CRED_FILE" ]; then
        set -a
        # shellcheck disable=SC1090
        . "$CRED_FILE"
        set +a
    fi
}
EOF
    chmod 644 "$libexec_dir/common.sh"

    # Helper: tailscaled-start
    cat << 'EOF' > "$helper_start"
#!/data/data/com.termux/files/usr/bin/env bash
# Helper script to start tailscaled in Termux.
#
# This is the single place where tailscaled's flags are assembled. The
# termux-services run script execs this with --foreground, so the service and
# the manual path cannot drift apart (and ~/.tailscale/.env applies to both).
set -euo pipefail

. "${PREFIX:-/data/data/com.termux/files/usr}/libexec/tailscale-termux/common.sh"

show_help() {
    echo "Tailscale Termux Start Helper"
    echo "============================="
    echo "Usage: tailscaled-start [options]"
    echo ""
    echo "Options:"
    echo "  --service=on      Enable tailscaled auto-start via termux-services"
    echo "  --service=off     Disable tailscaled auto-start via termux-services"
    echo "  --service=status  Check the termux-services status of tailscaled"
    echo "  --foreground      Run in the foreground (used by termux-services)"
    echo "  --help, -h        Show this help message"
    echo ""
    echo "Any other flags will be passed directly to the tailscaled daemon."
    echo "Configuration lives in $ENV_FILE; see 'tailscale-socks5' for the"
    echo "generated SOCKS5 credentials."
}

# Check for service control arguments
if [ $# -gt 0 ]; then
    case "$1" in
        --service=on)
            if ! command -v sv-enable >/dev/null 2>&1; then
                echo "Error: termux-services is not installed or initialized."
                exit 1
            fi
            echo "Enabling tailscaled in termux-services..."
            sv-enable tailscaled
            sv up tailscaled
            exit 0
            ;;
        --service=off)
            if ! command -v sv-disable >/dev/null 2>&1; then
                echo "Error: termux-services is not installed or initialized."
                exit 1
            fi
            echo "Disabling tailscaled in termux-services..."
            sv-disable tailscaled
            sv down tailscaled
            exit 0
            ;;
        --service=status)
            if ! command -v sv >/dev/null 2>&1; then
                echo "Error: termux-services is not installed or initialized."
                exit 1
            fi
            sv status tailscaled
            exit 0
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
    esac
fi

mkdir -p "$STATE_DIR"

FOREGROUND=0
USER_ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--foreground" ]; then
        FOREGROUND=1
    else
        USER_ARGS+=("$arg")
    fi
done

# In foreground mode runit owns the lifecycle: bailing out with 0 here would
# make runsv respawn us in a tight loop, so let tailscaled fail on the socket.
if [ "$FOREGROUND" -eq 0 ] && daemon_running; then
    echo "tailscaled is already running (pid $(daemon_pids))."
    exit 0
fi

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
fi

has_flag() {
    local pattern="$1" arg
    for arg in ${USER_ARGS[@]+"${USER_ARGS[@]}"}; do
        [ "$arg" = "$pattern" ] && return 0
        [ "${arg#"$pattern"=}" != "$arg" ] && return 0
    done
    return 1
}

# Value of "--flag=value" or "--flag value" from USER_ARGS.
flag_value() {
    local pattern="$1" i arg
    for ((i = 0; i < ${#USER_ARGS[@]}; i++)); do
        arg="${USER_ARGS[i]}"
        if [ "${arg#"$pattern"=}" != "$arg" ]; then
            printf '%s' "${arg#"$pattern"=}"
            return 0
        fi
        if [ "$arg" = "$pattern" ]; then
            # Bounds check: `tailscaled-start --socks5-server` with no value
            # used to abort with "USER_ARGS[i+1]: unbound variable".
            if [ $((i + 1)) -lt ${#USER_ARGS[@]} ]; then
                printf '%s' "${USER_ARGS[i + 1]}"
                return 0
            fi
            return 1
        fi
    done
    return 1
}

rand_secret() {
    local s=""
    if command -v openssl >/dev/null 2>&1; then
        s=$(openssl rand -hex 16 2>/dev/null || true)
    fi
    if [ -z "$s" ] && [ -r /dev/urandom ]; then
        s=$( (LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 24) || true )
    fi
    if [ -z "$s" ]; then
        s=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n' || true)
    fi
    if [ -z "$s" ]; then
        echo "Error: unable to generate a random SOCKS5 password." >&2
        return 1
    fi
    printf '%s' "$s"
}

# Generate SOCKS5 credentials once and persist them 0600.
#
# They reach the daemon through the environment, never as flags: Android's
# loopback is not isolated per app, and anything on argv is readable by every
# process on the device through /proc.
ensure_socks_creds() {
    if [ -z "${TS_SOCKS5_USER:-}" ] || [ -z "${TS_SOCKS5_PASS:-}" ]; then
        load_credentials
    fi
    if [ -n "${TS_SOCKS5_USER:-}" ] && [ -n "${TS_SOCKS5_PASS:-}" ]; then
        export TS_SOCKS5_USER TS_SOCKS5_PASS
        return 0
    fi

    TS_SOCKS5_USER="termux"
    TS_SOCKS5_PASS="$(rand_secret)"
    (
        umask 077
        cat > "$CRED_FILE" << CREDS
# Auto-generated SOCKS5 credentials for tailscaled.
# Show them with:      tailscale-socks5
# Regenerate them with: tailscale-socks5 --regenerate
TS_SOCKS5_USER=$TS_SOCKS5_USER
TS_SOCKS5_PASS=$TS_SOCKS5_PASS
CREDS
    )
    chmod 600 "$CRED_FILE"
    export TS_SOCKS5_USER TS_SOCKS5_PASS
    echo "Generated SOCKS5 credentials in $CRED_FILE (see: tailscale-socks5)."
}

FINAL_ARGS=()
has_flag "--statedir" || FINAL_ARGS+=("--statedir=$STATE_DIR")
has_flag "--socket" || FINAL_ARGS+=("--socket=$SOCKET")
has_flag "--tun" || FINAL_ARGS+=("--tun=userspace-networking")

# SOCKS5 proxy address. Set TS_SOCKS5=off to run without a proxy at all.
SOCKS_VAL=""
if has_flag "--socks5-server"; then
    SOCKS_VAL="$(flag_value "--socks5-server" || true)"
elif [ -n "${TS_SOCKS5_SERVER:-}" ]; then
    SOCKS_VAL="$TS_SOCKS5_SERVER"
elif [ -n "${TS_SOCKS5_PORT:-}" ]; then
    SOCKS_VAL="127.0.0.1:$TS_SOCKS5_PORT"
elif [ "${TS_SOCKS5:-on}" != "off" ]; then
    SOCKS_VAL="127.0.0.1:1055"
fi

if [ -n "$SOCKS_VAL" ]; then
    has_flag "--socks5-server" || FINAL_ARGS+=("--socks5-server=$SOCKS_VAL")
    case "${TS_SOCKS5_NO_AUTH:-}" in
        1 | true | yes | on)
            # Escape hatch for people upgrading with proxy clients that cannot
            # send credentials. It reopens the proxy to every app on the device.
            echo "Warning: TS_SOCKS5_NO_AUTH is set. The SOCKS5 proxy on $SOCKS_VAL"
            echo "         accepts any app on this device, with no password."
            unset TS_SOCKS5_USER TS_SOCKS5_PASS
            ;;
        *)
            ensure_socks_creds
            ;;
    esac
    printf '%s' "$SOCKS_VAL" > "$SOCKS_ADDR_FILE"
else
    rm -f "$SOCKS_ADDR_FILE"
fi

if ! has_flag "--outbound-http-proxy-listen" && [ -n "${TS_HTTP_PROXY:-}" ]; then
    FINAL_ARGS+=("--outbound-http-proxy-listen=$TS_HTTP_PROXY")
fi
if ! has_flag "--port" && [ -n "${TS_PORT:-}" ]; then
    FINAL_ARGS+=("--port=$TS_PORT")
fi

# tailscaled reads verbosity and log opt-out from the environment; `set -a`
# above already exported anything the user put in .env. These two lines only
# translate the names this project has documented historically.
if [ -n "${TS_VERBOSE:-}" ] && [ -z "${TS_LOG_VERBOSITY:-}" ]; then
    export TS_LOG_VERBOSITY="$TS_VERBOSE"
fi
if [ -n "${TS_NO_LOGS:-}" ] && [ -z "${TS_NO_LOGS_NO_SUPPORT:-}" ]; then
    export TS_NO_LOGS_NO_SUPPORT="$TS_NO_LOGS"
fi

FINAL_ARGS+=(${USER_ARGS[@]+"${USER_ARGS[@]}"})
if [ -n "${TS_EXTRA_ARGS:-}" ]; then
    # eval, not `read -ra`, so quoted values survive:
    # TS_EXTRA_ARGS='--hostname="my phone"' is one argument, not two.
    # .env is already sourced above, so this grants no new capability.
    eval "EXTRA_ARR=($TS_EXTRA_ARGS)"
    FINAL_ARGS+=(${EXTRA_ARR[@]+"${EXTRA_ARR[@]}"})
fi

if [ "$FOREGROUND" -eq 1 ]; then
    exec "$BIN_DIR/tailscaled" "${FINAL_ARGS[@]}"
fi

echo "Starting tailscaled..."
nohup "$BIN_DIR/tailscaled" "${FINAL_ARGS[@]}" >> "$LOG_FILE" 2>&1 &

sleep 2
if daemon_running; then
    if [ -n "$SOCKS_VAL" ]; then
        echo "Done. SOCKS5 address: $SOCKS_VAL (credentials: tailscale-socks5)"
    else
        echo "Done. SOCKS5 proxy disabled (TS_SOCKS5=off)."
    fi
else
    echo "Error: tailscaled failed to start. Check $LOG_FILE"
    exit 1
fi
EOF
    chmod +x "$helper_start"

    # Helper: tailscaled-stop
    cat << 'EOF' > "$helper_stop"
#!/data/data/com.termux/files/usr/bin/env bash
# Helper script to stop tailscaled in Termux
set -euo pipefail

. "${PREFIX:-/data/data/com.termux/files/usr}/libexec/tailscale-termux/common.sh"

STOPPED=0

# runit restarts anything it supervises, so killing the daemon under a
# want-up service just hands it straight back.
if service_present; then
    if sv status tailscaled 2>/dev/null | grep -q '^run:'; then
        echo "Stopping the tailscaled service..."
        sv down tailscaled
        STOPPED=1
    fi
fi

PIDS="$(daemon_pids)"
if [ -n "$PIDS" ]; then
    echo "Stopping tailscaled (pid $PIDS)..."
    # shellcheck disable=SC2086
    kill $PIDS 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        daemon_running || break
        sleep 0.5
    done
    PIDS="$(daemon_pids)"
    if [ -n "$PIDS" ]; then
        # shellcheck disable=SC2086
        kill -9 $PIDS 2>/dev/null || true
    fi
    STOPPED=1
fi

rm -f "$SOCKS_ADDR_FILE"

if [ "$STOPPED" -eq 1 ]; then
    echo "tailscaled stopped."
else
    echo "tailscaled was not running."
fi
EOF
    chmod +x "$helper_stop"

    # Helper: tailscaled-log
    cat << 'EOF' > "$helper_log"
#!/data/data/com.termux/files/usr/bin/env bash
# Helper script to view tailscaled logs in Termux
set -euo pipefail

. "${PREFIX:-/data/data/com.termux/files/usr}/libexec/tailscale-termux/common.sh"

# Under termux-services the daemon's output goes to svlogd, not to the nohup
# log file that only the manual start path writes.
if [ -f "$SVLOG_DIR/current" ]; then
    echo "-> Following $SVLOG_DIR/current (termux-services)"
    exec tail -f "$SVLOG_DIR/current"
fi

if [ -f "$LOG_FILE" ]; then
    echo "-> Following $LOG_FILE"
    exec tail -f "$LOG_FILE"
fi

echo "No log file found."
echo "  Looked in: $SVLOG_DIR/current"
echo "             $LOG_FILE"
echo "Is the daemon running? Try: tailscaled-start --service=status"
exit 1
EOF
    chmod +x "$helper_log"

    # Helper: tailscale-cli
    cat << 'EOF' > "$helper_cli"
#!/data/data/com.termux/files/usr/bin/env bash
# Helper script to run tailscale CLI with correct socket
set -euo pipefail

. "${PREFIX:-/data/data/com.termux/files/usr}/libexec/tailscale-termux/common.sh"

# An upgrade notice printed by dpkg scrolls past before anyone reads it, so
# repeat it once here, the next time the user actually reaches for the CLI.
NOTICE_FILE="$STATE_DIR/UPGRADE_NOTICE"
SHOWN_MARKER="$STATE_DIR/.upgrade_notice_shown"
if [ -f "$NOTICE_FILE" ] && [ ! -f "$SHOWN_MARKER" ]; then
    cat "$NOTICE_FILE" >&2
    echo "" >&2
    : > "$SHOWN_MARKER" 2>/dev/null || true
fi

# Auto-start daemon if socket is missing or process is not running
if [ ! -S "$SOCKET" ] || ! daemon_running; then
    echo "Notice: tailscaled is not running. Auto-starting daemon..."
    if service_present; then
        sv up tailscaled 2>/dev/null || true
    fi
    if ! daemon_running; then
        if [ -x "$BIN_DIR/tailscaled-start" ]; then
            "$BIN_DIR/tailscaled-start" >/dev/null 2>&1 &
        fi
    fi
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if [ -S "$SOCKET" ]; then break; fi
        sleep 0.5
    done
fi

exec "$BIN_DIR/tailscale" --socket="$SOCKET" "$@"
EOF
    chmod +x "$helper_cli"

    # Helper: tailscale-socks5
    cat << 'EOF' > "$helper_socks"
#!/data/data/com.termux/files/usr/bin/env bash
# Show (or regenerate) the SOCKS5 proxy credentials for tailscaled.
set -euo pipefail

. "${PREFIX:-/data/data/com.termux/files/usr}/libexec/tailscale-termux/common.sh"

usage() {
    echo "Usage: tailscale-socks5 [--regenerate] [--url] [--help]"
    echo ""
    echo "  (no flags)     Show the proxy address and credentials"
    echo "  --regenerate   Issue a new password (restart the daemon to apply)"
    echo "  --url          Print just the proxy URL, for scripts"
}

REGENERATE=0
URL_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --regenerate) REGENERATE=1 ;;
        --url) URL_ONLY=1 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

if [ "$REGENERATE" -eq 1 ]; then
    rm -f "$CRED_FILE"
    echo "Credentials cleared. Restart the daemon to issue new ones:"
    if service_present; then
        echo "  sv restart tailscaled"
    else
        echo "  tailscaled-stop && tailscaled-start"
    fi
    exit 0
fi

load_credentials

if [ -z "${TS_SOCKS5_USER:-}" ] || [ -z "${TS_SOCKS5_PASS:-}" ]; then
    echo "No SOCKS5 credentials yet. They are generated the first time the"
    echo "daemon starts. Start it with:"
    echo "  tailscaled-start"
    exit 1
fi

ADDR="$(live_socks_addr 2>/dev/null || true)"
SOURCE="running daemon"
if [ -z "$ADDR" ] && [ -f "$SOCKS_ADDR_FILE" ]; then
    ADDR="$(cat "$SOCKS_ADDR_FILE")"
    SOURCE="last recorded (daemon not running)"
fi

if [ -z "$ADDR" ]; then
    echo "SOCKS5 proxy address unknown — the daemon does not appear to be running."
    echo "Credentials on file: $TS_SOCKS5_USER / $TS_SOCKS5_PASS"
    exit 1
fi

if [ "$URL_ONLY" -eq 1 ]; then
    echo "socks5://$TS_SOCKS5_USER:$TS_SOCKS5_PASS@$ADDR"
    exit 0
fi

echo "Tailscale SOCKS5 Proxy"
echo "======================"
echo "Address  : $ADDR   ($SOURCE)"
echo "Username : $TS_SOCKS5_USER"
echo "Password : $TS_SOCKS5_PASS"
echo "URL      : socks5://$TS_SOCKS5_USER:$TS_SOCKS5_PASS@$ADDR"
echo ""
echo "Example  : curl --socks5-hostname $TS_SOCKS5_USER:$TS_SOCKS5_PASS@$ADDR https://api.ipify.org"
echo ""
echo "Anything on this device can reach $ADDR, so the password is what keeps"
echo "other apps from using your tailnet. Treat it as a secret."
EOF
    chmod +x "$helper_socks"

    # Helper: tailscale-test
    cat << 'EOF' > "$helper_test"
#!/data/data/com.termux/files/usr/bin/env bash
# Helper script to test tailscaled status and connectivity in Termux
set -euo pipefail

. "${PREFIX:-/data/data/com.termux/files/usr}/libexec/tailscale-termux/common.sh"

echo "Tailscale Functional Test"
echo "========================="
if ! daemon_running; then
    echo "[-] Error: tailscaled is not running."
    exit 1
fi

IP=$(tailscale-cli ip -4 2>/dev/null || echo "")
if [ -n "$IP" ]; then
    echo "[+] Authenticated. IP: $IP"
else
    echo "[-] Error: Not authenticated."
    exit 1
fi

# Ask the running daemon where it listens rather than trusting socks_addr,
# which goes stale whenever the daemon is restarted by another path.
SOCKS_ADDR="$(live_socks_addr 2>/dev/null || true)"
if [ -z "$SOCKS_ADDR" ] && [ -f "$SOCKS_ADDR_FILE" ]; then
    SOCKS_ADDR="$(cat "$SOCKS_ADDR_FILE")"
fi

if [ -z "$SOCKS_ADDR" ]; then
    echo "[*] SOCKS5 test skipped: the daemon is running without --socks5-server."
    echo "    Enable it by setting TS_SOCKS5_PORT in $ENV_FILE."
    echo "========================="
    exit 0
fi

load_credentials
CURL_AUTH=""
if [ -n "${TS_SOCKS5_USER:-}" ] && [ -n "${TS_SOCKS5_PASS:-}" ]; then
    CURL_AUTH="$TS_SOCKS5_USER:$TS_SOCKS5_PASS@"
else
    echo "[!] No credentials on file; testing the proxy unauthenticated."
fi

echo "[*] Testing SOCKS5 on $SOCKS_ADDR..."
if curl -s --socks5 "$CURL_AUTH$SOCKS_ADDR" https://1.1.1.1 > /dev/null; then
    echo "[+] SOCKS5 Connectivity (Direct IP): OK"
else
    echo "[-] SOCKS5 Connectivity (Direct IP): FAILED"
fi
if curl -s --socks5-hostname "$CURL_AUTH$SOCKS_ADDR" https://api.ipify.org > /dev/null; then
    echo "[+] SOCKS5 Resolution (Hostname): OK"
else
    echo "[-] SOCKS5 Resolution (Hostname): FAILED (DNS issue in daemon)"
    echo "    Tip: Use 'tailscale-cli up --accept-dns=false' or set global DNS in Admin Console."
fi
echo "========================="
EOF
    chmod +x "$helper_test"

    # Helper: tailscale-update (checks dpkg version and runs remote-install.sh if out of date)
    cat << 'EOF' > "$helper_update"
#!/data/data/com.termux/files/usr/bin/env bash
set -euo pipefail

echo "Checking for updates..."
REPO="bropines/tailscale-termux-cli"
# `|| true` because under `set -e` a failing grep (rate-limited API, no network)
# aborts the script on the assignment, making the check below unreachable.
LATEST_TAG=$(curl -fsS "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | grep -Po '"tag_name": "\K.*?(?=")' || true)

if [ -z "$LATEST_TAG" ]; then
    echo "Error: Could not retrieve latest release version."
    echo "       GitHub may be rate-limiting this IP; try again later."
    exit 1
fi

CURRENT_VERSION="unknown"
if command -v dpkg >/dev/null 2>&1; then
    CURRENT_VERSION=$(dpkg-query -W -f='${Version}' tailscale-termux 2>/dev/null || echo "unknown")
fi

CLEAN_LATEST=$(echo "$LATEST_TAG" | sed 's/^v//' | tr '-' '.')

if [ "$CLEAN_LATEST" = "$CURRENT_VERSION" ]; then
    echo "You are already on the latest version ($CURRENT_VERSION)."
    exit 0
fi

echo "New version available: $LATEST_TAG (Current: $CURRENT_VERSION)"
echo "Updating via remote installer..."
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/remote-install.sh" | bash
EOF
    chmod +x "$helper_update"

    # 4. Generate Debian Control File
    cat << EOF > "$pkg_dir/DEBIAN/control"
Package: tailscale-termux
Version: $DEB_VERSION
Architecture: $deb_arch
Maintainer: bropines <https://github.com/bropines/tailscale-termux-cli>
Depends: termux-services, curl, wget, procps, coreutils, zstd
Conflicts: tailscale
Replaces: tailscale
Section: net
Priority: optional
Homepage: https://github.com/bropines/tailscale-termux-cli
Description: Patched version of Tailscale CLI for Termux on Android 11+
EOF

    # 4.5 Post-install logic, shared by the .deb and the pacman package.
    # One implementation on the device rather than the same script written
    # twice into two different packaging formats.
    local notice_dir="$pkg_dir/data/data/com.termux/files/usr/share/tailscale-termux"
    mkdir -p "$notice_dir"
    cat << 'EOF' > "$notice_dir/upgrade-notice.txt"
==========================================================
 IMPORTANT: the SOCKS5 proxy now requires a password
==========================================================
Until this version the proxy on 127.0.0.1:1055 accepted any
connection. That meant every app on this phone could route
traffic through your tailnet as this node.

It now requires a username and password, generated for you
on the first daemon start. If a proxy client of yours stopped
working after this update, that is why.

  Show your credentials:   tailscale-socks5
  Copy a ready-made URL:   tailscale-socks5 --url

Also changed:
  * The manual `tailscaled-start` used to pick a random port
    each run; it now uses 127.0.0.1:1055, same as the service.
  * ~/.tailscale/.env is now read on BOTH start paths, not
    just the manual one.
  * TS_VERBOSE is now applied (as TS_LOG_VERBOSITY). If you
    had it set, expect more log output than before.

If a client genuinely cannot send SOCKS5 credentials, put
TS_SOCKS5_NO_AUTH=1 in ~/.tailscale/.env to restore the old
open proxy -- but understand you are reopening it to every
app on the device.

Delete this file to dismiss: rm ~/.tailscale/UPGRADE_NOTICE
==========================================================
EOF
    chmod 644 "$notice_dir/upgrade-notice.txt"

    cat << 'EOF' > "$libexec_dir/post-install.sh"
#!/data/data/com.termux/files/usr/bin/sh
# Shared post-install steps. $1 is "install" or "upgrade".
# Nothing here may fail the packaging transaction, so every step is guarded.
set -e

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TS_HOME="${HOME:-/data/data/com.termux/files/home}/.tailscale"
MODE="${1:-install}"

# svlogd exits fatally if its log directory is missing, which leaves runsv
# restarting the log service forever.
mkdir -p "$PREFIX/var/log/tailscaled" 2>/dev/null || true

if command -v termux-fix-shebang >/dev/null 2>&1; then
    termux-fix-shebang "$PREFIX/bin/tailscaled-start" \
                       "$PREFIX/bin/tailscaled-stop" \
                       "$PREFIX/bin/tailscaled-log" \
                       "$PREFIX/bin/tailscale-cli" \
                       "$PREFIX/bin/tailscale-test" \
                       "$PREFIX/bin/tailscale-update" \
                       "$PREFIX/bin/tailscale-socks5" \
                       "$PREFIX/var/service/tailscaled/run" 2>/dev/null || true
fi

# Only upgraders need warning that the proxy stopped accepting anonymous
# clients; a fresh install never had the old behaviour.
NOTICE_SRC="$PREFIX/share/tailscale-termux/upgrade-notice.txt"
if [ "$MODE" = "upgrade" ] && [ -f "$NOTICE_SRC" ] && mkdir -p "$TS_HOME" 2>/dev/null; then
    cp "$NOTICE_SRC" "$TS_HOME/UPGRADE_NOTICE" 2>/dev/null || true
    # Let tailscale-cli repeat it once: package manager output scrolls past.
    rm -f "$TS_HOME/.upgrade_notice_shown"
    echo ""
    cat "$TS_HOME/UPGRADE_NOTICE" 2>/dev/null || true
    echo ""
fi

if command -v sv-enable >/dev/null 2>&1; then
    sv-enable tailscaled 2>/dev/null || true
    sv up tailscaled 2>/dev/null || true
fi

exit 0
EOF
    chmod 755 "$libexec_dir/post-install.sh"

    # 4.6 Debian maintainer script
    cat << 'EOF' > "$pkg_dir/DEBIAN/postinst"
#!/data/data/com.termux/files/usr/bin/sh
set -e
PREFIX="/data/data/com.termux/files/usr"
# dpkg passes the previously installed version as $2 on an upgrade,
# and nothing on a fresh install.
if [ -n "${2:-}" ]; then MODE=upgrade; else MODE=install; fi
sh "$PREFIX/libexec/tailscale-termux/post-install.sh" "$MODE" || true
exit 0
EOF
    chmod 755 "$pkg_dir/DEBIAN/postinst"

    # 4.7 Fix shebangs for Termux environment
    if command -v termux-fix-shebang >/dev/null 2>&1; then
        echo "-> Fixing script shebangs for Termux..."
        termux-fix-shebang "$usr_bin_dir"/* 2>/dev/null || true
    fi

    # 5. Build .deb package
    echo "-> Compressing package with dpkg-deb (xz)..."
    dpkg-deb -Zxz --build "$pkg_dir"
    echo "-> Package created successfully: ${pkg_dir}.deb"

    # 6. Build the pacman package for Termux's pacman variant (issue #9)
    if command -v xz >/dev/null 2>&1; then
        echo "-> Building pacman package..."
        build_pacman_from_stage "$pkg_dir" "$arch"
    else
        echo "-> xz not found; skipping the pacman package."
    fi
}

# Ensure all required binaries are built before packaging to avoid race conditions
if [ "$TARGET_ARCH" = "all" ]; then
    ./build.sh all
else
    if ! binaries_are_current "$TARGET_ARCH"; then
        ./build.sh "$TARGET_ARCH"
    fi
fi

if [ "$TARGET_ARCH" = "all" ]; then
    ARCHES=(aarch64 arm i686 x86_64)
    PIDS=()
    for arch in "${ARCHES[@]}"; do
        build_deb_for_arch "$arch" &
        PIDS+=("$!")
    done
    # A bare `wait` always returns 0, so a failed package used to be announced
    # as "All requested packages built successfully".
    FAILED=""
    for i in "${!PIDS[@]}"; do
        if ! wait "${PIDS[$i]}"; then
            FAILED="$FAILED ${ARCHES[$i]}"
        fi
    done
    if [ -n "$FAILED" ]; then
        echo "Error: packaging failed for:$FAILED"
        exit 1
    fi
else
    build_deb_for_arch "$TARGET_ARCH"
fi

echo "All requested packages built successfully in '$DIST_DIR'."
