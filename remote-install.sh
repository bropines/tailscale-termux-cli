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
    echo "Loading environment from $ENV_FILE"
    set -a
    source "$ENV_FILE"
    set +a
fi

USER_ARGS=("\$@")
FINAL_ARGS=()

has_flag() {
    local pattern="\$1"
    for arg in "\${USER_ARGS[@]}"; do
        if [[ "\$arg" == "\$pattern"* ]]; then return 0; fi
    done
    return 1
}

has_flag "--statedir" || FINAL_ARGS+=("--statedir=$STATE_DIR")
has_flag "--socket" || FINAL_ARGS+=("--socket=$SOCKET")
has_flag "--tun" || FINAL_ARGS+=("--tun=userspace-networking")

if ! has_flag "--socks5-server"; then
    if [ -n "\${TS_SOCKS5_SERVER:-}" ]; then FINAL_ARGS+=("--socks5-server=\$TS_SOCKS5_SERVER")
    elif [ -n "\${TS_SOCKS5_PORT:-}" ]; then FINAL_ARGS+=("--socks5-server=localhost:\$TS_SOCKS5_PORT")
    else
        RANDOM_PORT=\$((RANDOM % 64511 + 1024))
        FINAL_ARGS+=("--socks5-server=localhost:\$RANDOM_PORT")
        echo "Using random SOCKS5 port: \$RANDOM_PORT"
    fi
fi

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
    echo "Error: tailscaled failed to start. Check $LOG_FILE"
    exit 1
fi
EOF

# Tailscaled STOP
cat << EOF > "$BIN_DIR/tailscaled-stop"
#!/usr/bin/env bash
echo "Stopping tailscaled..."
pkill -f "tailscaled.*$STATE_DIR" || echo "tailscaled was not running."
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

# Tailscale TEST
cat << 'EOF' > "$BIN_DIR/tailscale-test"
#!/usr/bin/env bash
echo "Tailscale Functional Test"
echo "========================="
PID=$(pgrep -f "tailscaled.*/data/data/com.termux/files/home/.tailscale")
if [ -z "$PID" ]; then echo "[-] Error: tailscaled is not running."; exit 1; fi
STATUS=$(tailscale-cli status --json 2>/dev/null)
if [[ $? -eq 0 ]] && echo "$STATUS" | grep -q '"BackendState": "Running"'; then
    echo "[+] Authenticated."
else echo "[-] Error: Not authenticated."; exit 1; fi
SOCKS_ADDR=$(ps -p "$PID" -o args= | grep -Po '--socks5-server=\K[^ ]+')
if [ -n "$SOCKS_ADDR" ]; then
    echo "[*] Testing SOCKS5 on $SOCKS_ADDR..."
    if curl -s --socks5-hostname "$SOCKS_ADDR" https://api.ipify.org > /dev/null; then
        echo "[+] SOCKS5 OK"
    else echo "[-] SOCKS5 FAILED"; fi
fi
EOF

chmod +x "$BIN_DIR/tailscaled-start" "$BIN_DIR/tailscaled-stop" "$BIN_DIR/tailscaled-log" "$BIN_DIR/tailscale-cli" "$BIN_DIR/tailscale-test"

echo "Installation Complete!"
echo "=============================="
echo "Commands: tailscaled-start, tailscaled-stop, tailscaled-log, tailscale-cli, tailscale-test"
