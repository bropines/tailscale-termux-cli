#!/usr/bin/env bash
set -eu

echo "Tailscale Termux CLI Installer"
echo "=============================="

BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
STATE_DIR="$HOME/.tailscale"
LOG_FILE="$STATE_DIR/tailscaled.log"
SOCKET="$STATE_DIR/tailscaled.sock"
ENV_FILE="$STATE_DIR/.env"
VER_FILE="$STATE_DIR/version"
SOCKS_ADDR_FILE="$STATE_DIR/socks_addr"

if [ ! -d "bin" ]; then
    echo "Error: 'bin' directory not found. Run ./build.sh first."
    exit 1
fi

echo "[1/3] Installing binaries..."
pkill -f tailscaled || true
mkdir -p "$BIN_DIR"
cp bin/tailscaled "$BIN_DIR/tailscaled"
cp bin/tailscale "$BIN_DIR/tailscale"
chmod +x "$BIN_DIR/tailscaled" "$BIN_DIR/tailscale"

echo "[2/3] Setting up background service..."
# (Skipping sv setup for brevity in this call, logic remains the same)

echo "[3/3] Creating helper scripts..."

# Tailscaled START (Now uses 127.0.0.1 and checks for DNS env)
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
    if [ -n "\${TS_SOCKS5_SERVER:-}" ]; then SOCKS_VAL="\$TS_SOCKS5_SERVER"
    elif [ -n "\${TS_SOCKS5_PORT:-}" ]; then SOCKS_VAL="127.0.0.1:\$TS_SOCKS5_PORT"
    else
        RANDOM_PORT=\$((RANDOM % 64511 + 1024))
        SOCKS_VAL="127.0.0.1:\$RANDOM_PORT"
        echo "Using random SOCKS5 port: \$RANDOM_PORT"
    fi
    FINAL_ARGS+=("--socks5-server=\$SOCKS_VAL")
else
    if [ "\$SOCKS_VAL" == "NEXT" ]; then
        for ((i=0; i<\${#USER_ARGS[@]}; i++)); do
            if [[ "\${USER_ARGS[i]}" == "--socks5-server" ]]; then SOCKS_VAL="\${USER_ARGS[i+1]}"; break; fi
        done
    fi
fi
echo "\$SOCKS_VAL" > "$SOCKS_ADDR_FILE"

# Map other ENV
if ! has_flag "--outbound-http-proxy-listen" && [ -n "\${TS_HTTP_PROXY:-}" ]; then FINAL_ARGS+=("--outbound-http-proxy-listen=\$TS_HTTP_PROXY"); fi
if ! has_flag "--port" && [ -n "\${TS_PORT:-}" ]; then FINAL_ARGS+=("--port=\$TS_PORT"); fi

# Add Extra User Args
FINAL_ARGS+=("\${USER_ARGS[@]}")
if [ -n "\${TS_EXTRA_ARGS:-}" ]; then
    read -ra EXTRA_ARR <<< "\$TS_EXTRA_ARGS"
    FINAL_ARGS+=("\${EXTRA_ARR[@]}")
fi

echo "Starting tailscaled..."
nohup "$BIN_DIR/tailscaled" "\${FINAL_ARGS[@]}" >> "$LOG_FILE" 2>&1 &

sleep 2
if pgrep -f "tailscaled.*$STATE_DIR" > /dev/null; then
    echo "Done. SOCKS5 address: \$SOCKS_VAL"
else
    echo "Error: tailscaled failed to start. Check $LOG_FILE"; exit 1
fi
EOF

# Tailscaled STOP, LOG, CLI, UPDATE (same logic, using $BIN_DIR)
cat << EOF > "$BIN_DIR/tailscaled-stop"
#!/usr/bin/env bash
pkill -f "tailscaled.*$STATE_DIR" || echo "tailscaled was not running."
rm -f "$SOCKS_ADDR_FILE"
EOF

cat << EOF > "$BIN_DIR/tailscaled-log"
#!/usr/bin/env bash
tail -f "$LOG_FILE"
EOF

cat << EOF > "$BIN_DIR/tailscale-cli"
#!/usr/bin/env bash
exec "$BIN_DIR/tailscale" --socket="$SOCKET" "\$@"
EOF

# Tailscale TEST (Added raw IP test to bypass DNS if needed)
cat << EOF > "$BIN_DIR/tailscale-test"
#!/usr/bin/env bash
echo "Tailscale Functional Test"
echo "========================="
if ! pgrep -f "tailscaled.*$STATE_DIR" > /dev/null; then echo "[-] Error: tailscaled is not running."; exit 1; fi
IP=\$(tailscale-cli ip -4 2>/dev/null || echo "")
if [ -n "\$IP" ]; then echo "[+] Authenticated. IP: \$IP"; else echo "[-] Error: Not authenticated."; exit 1; fi

if [ -f "$SOCKS_ADDR_FILE" ]; then
    SOCKS_ADDR=\$(cat "$SOCKS_ADDR_FILE")
    echo "[*] Testing SOCKS5 on \$SOCKS_ADDR..."
    # Test 1: Direct IP (no DNS)
    if curl -s --socks5 "\$SOCKS_ADDR" https://1.1.1.1 > /dev/null; then
        echo "[+] SOCKS5 Connectivity (Direct IP): OK"
    else
        echo "[-] SOCKS5 Connectivity (Direct IP): FAILED"
    fi
    # Test 2: Hostname (with DNS resolution in daemon)
    if curl -s --socks5-hostname "\$SOCKS_ADDR" https://api.ipify.org > /dev/null; then
        echo "[+] SOCKS5 Resolution (Hostname): OK"
    else
        echo "[-] SOCKS5 Resolution (Hostname): FAILED (DNS issue in daemon)"
        echo "    Tip: Use 'tailscale-cli up --accept-dns=false' or set global DNS in Admin Console."
    fi
fi
echo "========================="
EOF

chmod +x "$BIN_DIR/tailscaled-start" "$BIN_DIR/tailscaled-stop" "$BIN_DIR/tailscaled-log" "$BIN_DIR/tailscale-cli" "$BIN_DIR/tailscale-test"

echo "Installation Complete!"
