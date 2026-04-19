#!/usr/bin/env bash
set -eu

echo "Tailscale Termux Remote Installer"
echo "=============================="

# This script downloads and installs precompiled Tailscale binaries
# for Termux (Android 11+) directly from GitHub Releases.

REPO="bropines/tailscale-termux-cli"
TMP_DIR="$(mktemp -d)"
BIN_DIR="$HOME/bin"

echo "[1/3] Fetching latest release info..."
# Use curl/grep/sed as we don't assume 'jq' is installed in a fresh Termux
LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')

if [ -z "$LATEST_TAG" ]; then
    echo "Error: Could not find any releases. Please build it yourself or check the repo."
    exit 1
fi
echo "-> Latest Release: $LATEST_TAG"

echo "[2/3] Downloading binaries..."
# Github Actions artifacts aren't public as assets by default, we need a release.
# This script assumes assets 'tailscaled' and 'tailscale' exist in the release.
# If they are zipped, we would need to unzip them. Let's assume they are uploaded separately.
# Actually, GitHub Actions artifacts are not available as public direct URLs.
# So this script is for once you have a real GitHub Release.

DOWNLOAD_URL_DAEMON="https://github.com/$REPO/releases/download/$LATEST_TAG/tailscaled"
DOWNLOAD_URL_CLI="https://github.com/$REPO/releases/download/$LATEST_TAG/tailscale"

mkdir -p "$BIN_DIR"

echo "-> Downloading tailscaled..."
if ! wget -q --show-progress -O "$BIN_DIR/tailscaled" "$DOWNLOAD_URL_DAEMON"; then
    echo "Error: Failed to download tailscaled asset. Ensure the release has binary assets."
    exit 1
fi

echo "-> Downloading tailscale..."
if ! wget -q --show-progress -O "$BIN_DIR/tailscale" "$DOWNLOAD_URL_CLI"; then
    echo "Error: Failed to download tailscale asset. Ensure the release has binary assets."
    exit 1
fi

chmod +x "$BIN_DIR/tailscaled" "$BIN_DIR/tailscale"

echo "[3/3] Setting up start script..."
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
echo "You can now use: tailscaled-start"
