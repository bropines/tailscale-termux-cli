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

# Tailscaled START
cat << EOF > "$BIN_DIR/tailscaled-start"
#!/usr/bin/env bash
mkdir -p "$STATE_DIR"
if pgrep -f "tailscaled.*$STATE_DIR" > /dev/null; then
    echo "tailscaled is already running."
    exit 0
fi
echo "Starting tailscaled (logging to $LOG_FILE)..."
nohup "$BIN_DIR/tailscaled" \\
    --statedir="$STATE_DIR" \\
    --tun=userspace-networking \\
    --socks5-server=localhost:1055 \\
    --socket="$SOCKET" >> "$LOG_FILE" 2>&1 &
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

chmod +x "$BIN_DIR/tailscaled-start" "$BIN_DIR/tailscaled-stop" "$BIN_DIR/tailscaled-log" "$BIN_DIR/tailscale-cli"

echo "Installation Complete!"
echo "=============================="
echo "Commands:"
echo "  tailscaled-start  - Start daemon (with logging)"
echo "  tailscaled-stop   - Stop daemon"
echo "  tailscaled-log    - View logs"
echo "  tailscale-cli up  - Connect"
