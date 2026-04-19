#!/usr/bin/env bash
set -eu

echo "Tailscale Termux Remote Installer"
echo "=============================="

REPO="bropines/tailscale-termux-cli"
BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
STATE_DIR="$HOME/.tailscale"

echo "[1/3] Fetching latest release info..."
LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')

if [ -z "$LATEST_TAG" ]; then
    echo "Error: No releases found."
    exit 1
fi
echo "-> Latest Release: $LATEST_TAG"

echo "[2/3] Downloading binaries to $BIN_DIR..."
# Stop existing process to avoid 'Text file busy'
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

# Tailscaled STOP
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
echo "Commands: tailscaled-start, tailscaled-stop, tailscale-cli"
