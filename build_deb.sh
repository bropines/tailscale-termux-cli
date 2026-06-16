#!/usr/bin/env bash
# Tailscale Termux CLI Package Builder
set -eu

echo "Tailscale Termux Debian Package Builder"
echo "======================================="

# Determine version
if [ -z "${TS_VERSION:-}" ]; then
    # Try to find from git tag or default
    TS_VERSION=$(git describe --tags --always 2>/dev/null || echo "1.100.0")
fi
# Clean version string for debian (replace starting 'v' if present, replace dashes with tildes)
DEB_VERSION=$(echo "$TS_VERSION" | sed 's/^v//' | tr '-' '~')

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

    # Verify binaries exist, if not, build them
    if [ ! -f "$BIN_DIR/$arch/tailscale" ] || [ ! -f "$BIN_DIR/$arch/tailscaled" ]; then
        echo "Binaries for $arch not found. Building them first..."
        ./build.sh "$arch"
    fi

    # Define paths
    local pkg_dir="$DIST_DIR/tailscale-termux_${DEB_VERSION}_${deb_arch}"
    local usr_bin_dir="$pkg_dir/data/data/com.termux/files/usr/bin"
    local service_dir="$pkg_dir/data/data/com.termux/files/usr/var/service/tailscaled"

    # Clean previous build
    rm -rf "$pkg_dir"
    mkdir -p "$usr_bin_dir"
    mkdir -p "$service_dir/log"
    mkdir -p "$pkg_dir/DEBIAN"

    # 1. Copy main binaries
    cp "$BIN_DIR/$arch/tailscale" "$usr_bin_dir/tailscale"
    cp "$BIN_DIR/$arch/tailscaled" "$usr_bin_dir/tailscaled"
    chmod +x "$usr_bin_dir/tailscale" "$usr_bin_dir/tailscaled"

    # 2. Setup termux-services
    cp "$WORKDIR/termux-services/tailscaled/run" "$service_dir/run"
    chmod +x "$service_dir/run"

    # Create 'down' file so runit does not auto-start the service upon package installation
    touch "$service_dir/down"

    # Log service run script
    cat << 'EOF' > "$service_dir/log/run"
#!/data/data/com.termux/files/usr/bin/sh
exec svlogd -tt /data/data/com.termux/files/usr/var/log/tailscaled
EOF
    chmod +x "$service_dir/log/run"

    # 2.5 Setup shell autocompletions
    local completions_dir="$pkg_dir/data/data/com.termux/files/usr/share"
    local bash_comp_dir="$completions_dir/bash-completion/completions"
    local zsh_comp_dir="$completions_dir/zsh/site-functions"
    local fish_comp_dir="$completions_dir/fish/vendor_completions.d"

    mkdir -p "$bash_comp_dir" "$zsh_comp_dir" "$fish_comp_dir"

    echo "-> Generating shell completions..."
    cd "$SRC_DIR"
    go run ./cmd/tailscale completion bash > "$bash_comp_dir/tailscale"
    go run ./cmd/tailscale completion zsh > "$zsh_comp_dir/_tailscale"
    go run ./cmd/tailscale completion fish > "$fish_comp_dir/tailscale.fish"
    cd "$WORKDIR"

    # Register tailscale-cli shell integrations
    echo "complete -F _tailscale tailscale-cli" > "$bash_comp_dir/tailscale-cli"
    
    cat << 'EOF' > "$zsh_comp_dir/_tailscale-cli"
#compdef tailscale-cli
compdef tailscale-cli=tailscale
EOF

    echo "complete -c tailscale-cli -w tailscale" > "$fish_comp_dir/tailscale-cli.fish"

    # 3. Create helper scripts in bin
    local helper_start="$usr_bin_dir/tailscaled-start"
    local helper_stop="$usr_bin_dir/tailscaled-stop"
    local helper_log="$usr_bin_dir/tailscaled-log"
    local helper_cli="$usr_bin_dir/tailscale-cli"
    local helper_test="$usr_bin_dir/tailscale-test"
    local helper_update="$usr_bin_dir/tailscale-update"

    # Helper: tailscaled-start
    cat << 'EOF' > "$helper_start"
#!/usr/bin/env bash
# Helper script to start tailscaled in Termux
set -eu

STATE_DIR="$HOME/.tailscale"
LOG_FILE="$STATE_DIR/tailscaled.log"
SOCKET="$STATE_DIR/tailscaled.sock"
ENV_FILE="$STATE_DIR/.env"
SOCKS_ADDR_FILE="$STATE_DIR/socks_addr"
BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"

# Help message
show_help() {
    echo "Tailscale Termux Start Helper"
    echo "============================="
    echo "Usage: tailscaled-start [options]"
    echo ""
    echo "Options:"
    echo "  --service=on      Enable tailscaled auto-start via termux-services"
    echo "  --service=off     Disable tailscaled auto-start via termux-services"
    echo "  --service=status  Check the termux-services status of tailscaled"
    echo "  --help, -h        Show this help message"
    echo ""
    echo "Any other flags will be passed directly to the tailscaled daemon."
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
if pgrep -f "tailscaled.*$STATE_DIR" > /dev/null; then
    echo "tailscaled is already running."
    exit 0
fi

if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

USER_ARGS=("$@")
FINAL_ARGS=()
SOCKS_VAL=""

has_flag() {
    local pattern="$1"
    for arg in "${USER_ARGS[@]}"; do
        if [[ "$arg" == "$pattern"* ]]; then
            if [[ "$arg" == *"="* ]]; then SOCKS_VAL="${arg#*=}"; else SOCKS_VAL="NEXT"; fi
            return 0
        fi
    done
    return 1
}

has_flag "--statedir" || FINAL_ARGS+=("--statedir=$STATE_DIR")
has_flag "--socket" || FINAL_ARGS+=("--socket=$SOCKET")
has_flag "--tun" || FINAL_ARGS+=("--tun=userspace-networking")

if ! has_flag "--socks5-server"; then
    if [ -n "${TS_SOCKS5_SERVER:-}" ]; then SOCKS_VAL="$TS_SOCKS5_SERVER"
    elif [ -n "${TS_SOCKS5_PORT:-}" ]; then SOCKS_VAL="127.0.0.1:$TS_SOCKS5_PORT"
    else
        RANDOM_PORT=$((RANDOM % 64511 + 1024))
        SOCKS_VAL="127.0.0.1:$RANDOM_PORT"
        echo "Using random SOCKS5 port: $RANDOM_PORT"
    fi
    FINAL_ARGS+=("--socks5-server=$SOCKS_VAL")
else
    if [ "$SOCKS_VAL" == "NEXT" ]; then
        for ((i=0; i<${#USER_ARGS[@]}; i++)); do
            if [[ "${USER_ARGS[i]}" == "--socks5-server" ]]; then SOCKS_VAL="${USER_ARGS[i+1]}"; break; fi
        done
    fi
fi
echo "$SOCKS_VAL" > "$SOCKS_ADDR_FILE"

if ! has_flag "--outbound-http-proxy-listen" && [ -n "${TS_HTTP_PROXY:-}" ]; then FINAL_ARGS+=("--outbound-http-proxy-listen=$TS_HTTP_PROXY"); fi
if ! has_flag "--port" && [ -n "${TS_PORT:-}" ]; then FINAL_ARGS+=("--port=$TS_PORT"); fi

FINAL_ARGS+=("${USER_ARGS[@]}")
if [ -n "${TS_EXTRA_ARGS:-}" ]; then
    read -ra EXTRA_ARR <<< "$TS_EXTRA_ARGS"
    FINAL_ARGS+=("${EXTRA_ARR[@]}")
fi

echo "Starting tailscaled..."
nohup "$BIN_DIR/tailscaled" "${FINAL_ARGS[@]}" >> "$LOG_FILE" 2>&1 &

sleep 2
if pgrep -f "tailscaled.*$STATE_DIR" > /dev/null; then
    echo "Done. SOCKS5 address: $SOCKS_VAL"
else
    echo "Error: tailscaled failed to start. Check $LOG_FILE"
    exit 1
fi
EOF
    chmod +x "$helper_start"

    # Helper: tailscaled-stop
    cat << 'EOF' > "$helper_stop"
#!/usr/bin/env bash
# Helper script to stop tailscaled in Termux
set -eu

STATE_DIR="$HOME/.tailscale"
SOCKS_ADDR_FILE="$STATE_DIR/socks_addr"

pkill -f "tailscaled.*$STATE_DIR" || echo "tailscaled was not running."
rm -f "$SOCKS_ADDR_FILE"
EOF
    chmod +x "$helper_stop"

    # Helper: tailscaled-log
    cat << 'EOF' > "$helper_log"
#!/usr/bin/env bash
# Helper script to view tailscaled logs in Termux
set -eu

STATE_DIR="$HOME/.tailscale"
LOG_FILE="$STATE_DIR/tailscaled.log"

tail -f "$LOG_FILE"
EOF
    chmod +x "$helper_log"

    # Helper: tailscale-cli
    cat << 'EOF' > "$helper_cli"
#!/usr/bin/env bash
# Helper script to run tailscale CLI with correct socket
set -eu

STATE_DIR="$HOME/.tailscale"
SOCKET="$STATE_DIR/tailscaled.sock"
BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"

exec "$BIN_DIR/tailscale" --socket="$SOCKET" "$@"
EOF
    chmod +x "$helper_cli"

    # Helper: tailscale-test
    cat << 'EOF' > "$helper_test"
#!/usr/bin/env bash
# Helper script to test tailscaled status and connectivity in Termux
set -eu

STATE_DIR="$HOME/.tailscale"
SOCKS_ADDR_FILE="$STATE_DIR/socks_addr"

echo "Tailscale Functional Test"
echo "========================="
if ! pgrep -f "tailscaled.*$STATE_DIR" > /dev/null; then
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

if [ -f "$SOCKS_ADDR_FILE" ]; then
    SOCKS_ADDR=$(cat "$SOCKS_ADDR_FILE")
    echo "[*] Testing SOCKS5 on $SOCKS_ADDR..."
    if curl -s --socks5 "$SOCKS_ADDR" https://1.1.1.1 > /dev/null; then
        echo "[+] SOCKS5 Connectivity (Direct IP): OK"
    else
        echo "[-] SOCKS5 Connectivity (Direct IP): FAILED"
    fi
    if curl -s --socks5-hostname "$SOCKS_ADDR" https://api.ipify.org > /dev/null; then
        echo "[+] SOCKS5 Resolution (Hostname): OK"
    else
        echo "[-] SOCKS5 Resolution (Hostname): FAILED (DNS issue in daemon)"
        echo "    Tip: Use 'tailscale-cli up --accept-dns=false' or set global DNS in Admin Console."
    fi
fi
echo "========================="
EOF
    chmod +x "$helper_test"

    # Helper: tailscale-update (checks dpkg version and runs remote-install.sh if out of date)
    cat << 'EOF' > "$helper_update"
#!/usr/bin/env bash
set -eu

echo "Checking for updates..."
REPO="bropines/tailscale-termux-cli"
LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')

if [ -z "$LATEST_TAG" ]; then
    echo "Error: Could not retrieve latest release version."
    exit 1
fi

CURRENT_VERSION="unknown"
if command -v dpkg >/dev/null 2>&1; then
    CURRENT_VERSION=$(dpkg-query -W -f='${Version}' tailscale-termux 2>/dev/null || echo "unknown")
fi

CLEAN_LATEST=$(echo "$LATEST_TAG" | sed 's/^v//' | tr '-' '~')

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
Depends: termux-services, curl, wget, procps, coreutils
Conflicts: tailscale
Replaces: tailscale
Section: net
Priority: optional
Homepage: https://github.com/bropines/tailscale-termux-cli
Description: Patched version of Tailscale CLI for Termux on Android 11+
EOF

    # 5. Build .deb package
    echo "-> Compressing package with dpkg-deb..."
    dpkg-deb --build "$pkg_dir"
    echo "-> Package created successfully: ${pkg_dir}.deb"
}

if [ "$TARGET_ARCH" = "all" ]; then
    for arch in aarch64 arm i686 x86_64; do
        build_deb_for_arch "$arch"
    done
else
    build_deb_for_arch "$TARGET_ARCH"
fi

echo "All requested packages built successfully in '$DIST_DIR'."
