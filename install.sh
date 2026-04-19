#!/usr/bin/env bash
set -eu

echo "Tailscale Termux CLI Installer"
echo "=============================="

# Use Termux standard bin directory
BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
SV_DIR="${PREFIX:-/data/data/com.termux/files/usr}/var/service/tailscaled"
SRC_BIN_DIR="bin"
STATE_DIR="$HOME/.tailscale"

if [ ! -d "$SRC_BIN_DIR" ]; then
    echo "Error: 'bin' directory not found. Please run ./build.sh first."
    exit 1
fi

echo "[1/3] Installing binaries to $BIN_DIR..."
# Stop existing process to avoid 'Text file busy'
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

# Tailscaled START script
cat << EOF > "$BIN_DIR/tailscaled-start"
#!/usr/bin/env bash
mkdir -p "$STATE_DIR"
if pgrep -f "tailscaled.*$STATE_DIR" > /dev/null; then
    echo "tailscaled is already running."
    exit 0
fi
echo "Starting tailscaled in background..."
"$BIN_DIR/tailscaled" \\
    --statedir="$STATE_DIR" \\
    --tun=userspace-networking \\
    --socks5-server=localhost:1055 \\
    --socket="$STATE_DIR/tailscaled.sock" > /dev/null 2>&1 &
sleep 2
if pgrep -f "tailscaled.*$STATE_DIR" > /dev/null; then
    echo "Done. Use 'tailscale status' to check."
else
    echo "Error: tailscaled failed to start."
    exit 1
fi
EOF

# Tailscaled STOP script
cat << EOF > "$BIN_DIR/tailscaled-stop"
#!/usr/bin/env bash
echo "Stopping tailscaled..."
pkill -f "tailscaled.*$STATE_DIR" || echo "tailscaled was not running."
EOF

# Aliased tailscale CLI
cat << EOF > "$BIN_DIR/tailscale-cli"
#!/usr/bin/env bash
exec "$BIN_DIR/tailscale" --socket="$STATE_DIR/tailscaled.sock" "\$@"
EOF

chmod +x "$BIN_DIR/tailscaled-start" "$BIN_DIR/tailscaled-stop" "$BIN_DIR/tailscale-cli"

echo "Installation Complete!"
echo "=============================="
echo "Commands:"
echo "  tailscaled-start  - Start daemon"
echo "  tailscaled-stop   - Stop daemon"
echo "  tailscale-cli up  - Connect"
