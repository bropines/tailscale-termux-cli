#!/usr/bin/env bash
set -eu

echo "Tailscale Termux CLI Installer"
echo "=============================="

# This script installs precompiled binaries (locally built or downloaded)
# into your Termux environment and offers to set up background services.

BIN_DIR="$HOME/bin"
SV_DIR="$PREFIX/var/service/tailscaled"
SRC_BIN_DIR="bin"

if [ ! -d "$SRC_BIN_DIR" ]; then
    echo "Error: 'bin' directory not found. Please run ./build.sh first."
    exit 1
fi

echo "[1/3] Installing binaries to $BIN_DIR..."
mkdir -p "$BIN_DIR"
cp "$SRC_BIN_DIR/tailscaled" "$BIN_DIR/tailscaled"
cp "$SRC_BIN_DIR/tailscale" "$BIN_DIR/tailscale"
chmod +x "$BIN_DIR/tailscaled" "$BIN_DIR/tailscale"

echo "[2/3] Setting up background service..."
# Check for termux-services and sv
if command -v sv >/dev/null 2>&1; then
    echo "-> termux-services detected."
    # Use read if in interactive terminal
    if [ -t 0 ]; then
        echo -n "Would you like to install tailscaled as a Termux service (sv)? [y/N]: "
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            mkdir -p "$SV_DIR/log"
            cp -r termux-services/tailscaled/* "$SV_DIR/"
            chmod +x "$SV_DIR/run" "$SV_DIR/log/run"
            mkdir -p "$HOME/.tailscale"
            sv-enable tailscaled || true
            echo "-> Service installed and enabled (sv start tailscaled)."
        else
            echo "-> Service installation skipped."
        fi
    fi
else
    echo "-> termux-services (sv) not installed. Skipping automatic service setup."
fi

echo "[3/3] Creating a helper launch script..."
cat << 'EOF' > "$BIN_DIR/tailscaled-start"
#!/usr/bin/env bash
mkdir -p "$HOME/.tailscale"
echo "Starting tailscaled in background..."
nohup "$HOME/bin/tailscaled" \
    --statedir="$HOME/.tailscale" \
    --tun=userspace-networking \
    --socks5-server=localhost:1055 \
    >/dev/null 2>&1 &
echo "Done. Use 'tailscale status' to check."
EOF
chmod +x "$BIN_DIR/tailscaled-start"

echo "Installation Complete!"
echo "=============================="
echo "You can now start Tailscale with one command:"
echo "  tailscaled-start"
echo
echo "To authenticate:"
echo "  tailscale up"
