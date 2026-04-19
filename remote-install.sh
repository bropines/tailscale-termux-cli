#!/usr/bin/env bash
set -eu

echo "Tailscale Termux Remote Installer"
echo "=============================="

REPO="bropines/tailscale-termux-cli"
BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
STATE_DIR="$HOME/.tailscale"
LOG_FILE="$STATE_DIR/tailscaled.log"
SOCKET="$STATE_DIR/tailscaled.sock"
ENV_FILE="$STATE_DIR/.env"
VER_FILE="$STATE_DIR/version"
SOCKS_ADDR_FILE="$STATE_DIR/socks_addr"

echo "[1/3] Fetching latest release info..."
LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')

if [ -z "$LATEST_TAG" ]; then
    echo "Error: No releases found."
    exit 1
fi
echo "-> Latest Release: $LATEST_TAG"

echo "[2/3] Downloading binaries to $BIN_DIR..."
pkill -f tailscaled || true
mkdir -p "$BIN_DIR"
wget -q --show-progress -O "$BIN_DIR/tailscaled" "https://github.com/$REPO/releases/download/$LATEST_TAG/tailscaled"
wget -q --show-progress -O "$BIN_DIR/tailscale" "https://github.com/$REPO/releases/download/$LATEST_TAG/tailscale"
chmod +x "$BIN_DIR/tailscaled" "$BIN_DIR/tailscale"

# Save installed version
mkdir -p "$STATE_DIR"
echo "$LATEST_TAG" > "$VER_FILE"

echo "[3/3] Setting up helper scripts..."

# Tailscaled START
cat << EOF > "$BIN_DIR/tailscaled-start"
#!/usr/bin/env bash
mkdir -p "$STATE_DIR"
if pgrep -f "tailscaled.*$STATE_DIR" > /dev/null; then
    echo "tailscaled is already running."
    exit 0
fi

if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

USER_ARGS=("\$@")
FINAL_ARGS=()
SOCKS_VAL=""

has_flag() {
    local pattern="\$1"
    for arg in "\${USER_ARGS[@]}"; do
        if [[ "\$arg" == "\$pattern"* ]]; then
            if [[ "\$arg" == *"="* ]]; then SOCKS_VAL="\${arg#*=}"; else SOCKS_VAL="NEXT"; fi
            return 0
        fi
    done
    return 1
}

has_flag "--statedir" || FINAL_ARGS+=("--statedir=$STATE_DIR")
has_flag "--socket" || FINAL_ARGS+=("--socket=$SOCKET")
has_flag "--tun" || FINAL_ARGS+=("--tun=userspace-networking")

if ! has_flag "--socks5-server"; then
    if [ -n "\${TS_SOCKS5_SERVER:-}" ]; then 
        SOCKS_VAL="\$TS_SOCKS5_SERVER"
    elif [ -n "\${TS_SOCKS5_PORT:-}" ]; then 
        SOCKS_VAL="localhost:\$TS_SOCKS5_PORT"
    else
        RANDOM_PORT=\$((RANDOM % 64511 + 1024))
        SOCKS_VAL="localhost:\$RANDOM_PORT"
        echo "Using random SOCKS5 port: \$RANDOM_PORT"
    fi
    FINAL_ARGS+=("--socks5-server=\$SOCKS_VAL")
else
    if [ "\$SOCKS_VAL" == "NEXT" ]; then
        for ((i=0; i<\${#USER_ARGS[@]}; i++)); do
            if [[ "\${USER_ARGS[i]}" == "--socks5-server" ]]; then
                SOCKS_VAL="\${USER_ARGS[i+1]}"
                break
            fi
        done
    fi
fi

echo "\$SOCKS_VAL" > "$SOCKS_ADDR_FILE"

if ! has_flag "--outbound-http-proxy-listen" && [ -n "\${TS_HTTP_PROXY:-}" ]; then FINAL_ARGS+=("--outbound-http-proxy-listen=\$TS_HTTP_PROXY"); fi
if ! has_flag "--port" && [ -n "\${TS_PORT:-}" ]; then FINAL_ARGS+=("--port=\$TS_PORT"); fi
if ! has_flag "--debug" && [ -n "\${TS_DEBUG:-}" ]; then FINAL_ARGS+=("--debug=\$TS_DEBUG"); fi
if ! has_flag "--verbose" && [ -n "\${TS_VERBOSE:-}" ]; then FINAL_ARGS+=("--verbose=\$TS_VERBOSE"); fi
if ! has_flag "--no-logs-no-support" && [[ "\${TS_NO_LOGS:-}" == "true" ]]; then FINAL_ARGS+=("--no-logs-no-support"); fi

FINAL_ARGS+=("\${USER_ARGS[@]}")
if [ -n "\${TS_EXTRA_ARGS:-}" ]; then
    read -ra EXTRA_ARR <<< "\$TS_EXTRA_ARGS"
    FINAL_ARGS+=("\${EXTRA_ARR[@]}")
fi

echo "Starting tailscaled..."
nohup "$BIN_DIR/tailscaled" "\${FINAL_ARGS[@]}" >> "$LOG_FILE" 2>&1 &

sleep 2
if pgrep -f "tailscaled.*$STATE_DIR" > /dev/null; then
    echo "Done. Use 'tailscale-cli status' to check."
else
    echo "Error: tailscaled failed to start. Check $LOG_FILE"; exit 1
fi
EOF

# Tailscaled STOP
cat << EOF > "$BIN_DIR/tailscaled-stop"
#!/usr/bin/env bash
echo "Stopping tailscaled..."
pkill -f "tailscaled.*$STATE_DIR" || echo "tailscaled was not running."
rm -f "$SOCKS_ADDR_FILE"
EOF

# Tailscaled LOG
cat << EOF > "$BIN_DIR/tailscaled-log"
#!/usr/bin/env bash
tail -f "$LOG_FILE"
EOF

# Tailscale CLI
cat << EOF > "$BIN_DIR/tailscale-cli"
#!/usr/bin/env bash
exec "$BIN_DIR/tailscale" --socket="$SOCKET" "\$@"
EOF

# Tailscale UPDATE
cat << EOF > "$BIN_DIR/tailscale-update"
#!/usr/bin/env bash
echo "Checking for updates..."
REPO="bropines/tailscale-termux-cli"
LATEST_TAG=\$(curl -s "https://api.github.com/repos/\$REPO/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')
CURRENT_VERSION="unknown"
if [ -f "$VER_FILE" ]; then CURRENT_VERSION=\$(cat "$VER_FILE"); fi
if [ "\$LATEST_TAG" == "\$CURRENT_VERSION" ]; then
    echo "You are already on the latest version (\$CURRENT_VERSION)."
    exit 0
fi
echo "New version available: \$LATEST_TAG (Current: \$CURRENT_VERSION)"
curl -fsSL https://raw.githubusercontent.com/\$REPO/main/remote-install.sh | bash
EOF

# Tailscale TEST
cat << EOF > "$BIN_DIR/tailscale-test"
#!/usr/bin/env bash
echo "Tailscale Functional Test"
echo "========================="
if ! pgrep -f "tailscaled.*$STATE_DIR" > /dev/null; then
    echo "[-] Error: tailscaled is not running."
    exit 1
fi
echo "[+] Daemon is running."
IP=\$(tailscale-cli ip -4 2>/dev/null || echo "")
if [ -n "\$IP" ]; then
    echo "[+] Authenticated. IP: \$IP"
else
    echo "[-] Error: Not authenticated."
    exit 1
fi
if [ -f "$SOCKS_ADDR_FILE" ]; then
    SOCKS_ADDR=\$(cat "$SOCKS_ADDR_FILE")
    echo "[*] Testing SOCKS5 on \$SOCKS_ADDR..."
    EXT_IP=\$(curl -s --socks5-hostname "\$SOCKS_ADDR" https://api.ipify.org || echo "")
    if [ -n "\$EXT_IP" ]; then echo "[+] SOCKS5 OK (External IP: \$EXT_IP)"; else echo "[-] SOCKS5 FAILED"; fi
fi
echo "========================="
EOF

chmod +x "$BIN_DIR/tailscaled-start" "$BIN_DIR/tailscaled-stop" "$BIN_DIR/tailscaled-log" "$BIN_DIR/tailscale-cli" "$BIN_DIR/tailscale-update" "$BIN_DIR/tailscale-test"

echo "Installation Complete!"
echo "=============================="
echo "Commands: tailscaled-start, tailscaled-stop, tailscaled-log, tailscale-cli, tailscale-test, tailscale-update"
