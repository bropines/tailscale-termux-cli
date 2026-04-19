#!/usr/bin/env bash
set -eu

echo "Tailscale Termux CLI Installer"
echo "=============================="

BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
SV_DIR="${PREFIX:-/data/data/com.termux/files/usr}/var/service/tailscaled"
SRC_BIN_DIR="bin"
STATE_DIR="$HOME/.tailscale"
LOG_FILE="$STATE_DIR/tailscaled.log"
SOCKET="$STATE_DIR/tailscaled.sock"
ENV_FILE="$STATE_DIR/.env"

if [ ! -d "$SRC_BIN_DIR" ]; then
    echo "Error: 'bin' directory not found. Please run ./build.sh first."
    exit 1
fi

echo "[1/3] Installing binaries to $BIN_DIR..."
pkill -f tailscaled || true
mkdir -p "$BIN_DIR"
cp "$SRC_BIN_DIR/tailscaled" "$BIN_DIR/tailscaled"
cp "$SRC_BIN_DIR/tailscale" "$BIN_DIR/tailscale"
chmod +x "$BIN_DIR/tailscaled" "$BIN_DIR/tailscale"

echo "[2/3] Setting up background service..."
if command -v sv >/dev/null 2>&1; then
    if [ -t 0 ]; then
        echo -n "Would you like to install tailscaled as a Termux service (sv)? [y/N]: "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            mkdir -p "$SV_DIR/log"
            cp -r termux-services/tailscaled/* "$SV_DIR/"
            chmod +x "$SV_DIR/run" "$SV_DIR/log/run"
            mkdir -p "$STATE_DIR"
            sv-enable tailscaled || true
            echo "-> Service installed. Use 'sv start tailscaled' to run."
        fi
    fi
fi

echo "[3/3] Creating helper scripts..."

# Tailscaled START (Smart wrapper with random port and .env support)
cat << EOF > "$BIN_DIR/tailscaled-start"
#!/usr/bin/env bash
mkdir -p "$STATE_DIR"
if pgrep -f "tailscaled.*$STATE_DIR" > /dev/null; then
    echo "tailscaled is already running."
    exit 0
fi

# Load environment variables if .env exists
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

# Add defaults if not overridden
has_flag "--statedir" || FINAL_ARGS+=("--statedir=$STATE_DIR")
has_flag "--socket" || FINAL_ARGS+=("--socket=$SOCKET")
has_flag "--tun" || FINAL_ARGS+=("--tun=userspace-networking")

# Randomize SOCKS5 port if not provided
if ! has_flag "--socks5-server"; then
    RANDOM_PORT=\$((RANDOM % 64511 + 1024))
    FINAL_ARGS+=("--socks5-server=localhost:\$RANDOM_PORT")
    echo "Using random SOCKS5 port: \$RANDOM_PORT"
fi

# Add user overrides/extras
FINAL_ARGS+=("\${USER_ARGS[@]}")

echo "Starting tailscaled..."
echo "Logging to $LOG_FILE"

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

# Tailscale CLI alias
cat << EOF > "$BIN_DIR/tailscale-cli"
#!/usr/bin/env bash
exec "$BIN_DIR/tailscale" --socket="$SOCKET" "\$@"
EOF

# Tailscale TEST (Smart port detection)
cat << 'EOF' > "$BIN_DIR/tailscale-test"
#!/usr/bin/env bash
echo "Tailscale Functional Test"
echo "========================="

# 1. Check daemon
PID=$(pgrep -f "tailscaled.*/data/data/com.termux/files/home/.tailscale")
if [ -z "$PID" ]; then
    echo "[-] Error: tailscaled is not running."
    exit 1
fi
echo "[+] Daemon is running (PID: $PID)."

# 2. Check Auth
STATUS=$(tailscale-cli status --json 2>/dev/null)
if [[ $? -eq 0 ]] && echo "$STATUS" | grep -q '"BackendState": "Running"'; then
    IP=$(echo "$STATUS" | grep -Po '"Self":.*?,"IPv4": "\K.*?(?=")')
    echo "[+] Authenticated. Your Tailscale IP: $IP"
else
    echo "[-] Error: Not authenticated. Run 'tailscale-cli up'."
    exit 1
fi

# 3. Detect SOCKS5 port from running process
SOCKS_ADDR=$(ps -p "$PID" -o args= | grep -Po '--socks5-server=\K[^ ]+')
if [ -z "$SOCKS_ADDR" ]; then
    echo "[-] Error: Could not detect SOCKS5 port from tailscaled process."
    exit 1
fi
echo "[*] Detected SOCKS5 proxy on: $SOCKS_ADDR"

# 4. Test SOCKS5
EXT_IP=$(curl -s --socks5-hostname "$SOCKS_ADDR" https://api.ipify.org)
if [ -n "$EXT_IP" ]; then
    echo "[+] SOCKS5 Connectivity: OK (IP: $EXT_IP)"
else
    echo "[-] SOCKS5 Connectivity: FAILED"
fi

echo "========================="
echo "Tests completed!"
EOF

chmod +x "$BIN_DIR/tailscaled-start" "$BIN_DIR/tailscaled-stop" "$BIN_DIR/tailscaled-log" "$BIN_DIR/tailscale-cli" "$BIN_DIR/tailscale-test"

echo "Installation Complete!"
echo "=============================="
echo "Commands: tailscaled-start, tailscaled-stop, tailscaled-log, tailscale-cli, tailscale-test"
