# Tailscale Termux CLI (Android 11+ Ready)

This project provides a patched version of the official Tailscale CLI (tailscale and tailscaled) designed specifically to run inside Termux on Android 11 and above.

## The Netmon Patch
On Android 11+ (API 30+), Google restricted access to netlink, which Tailscale uses to monitor network interfaces. This causes the official binary to fail with permission denied.

This patch (originally inspired by the work of [asutorufa](https://github.com/Asutorufa/tailscale)):
1. Bypasses Netlink: Intercepts the interface discovery process.
2. Uses ifconfig Parser: Executes and parses the output of ifconfig (which still works via ioctl) to find real IP addresses (Wi-Fi, Mobile Data, etc.).
3. Userspace Networking: Optimized to run without Root or /dev/net/tun by leveraging Tailscale's userspace networking engine.

## Installation

### Option 1: Remote Installer (Easiest)
Run this command in Termux to download and install the latest precompiled binaries from GitHub:
```bash
curl -fsSL https://raw.githubusercontent.com/bropines/tailscale-termux-cli/main/remote-install.sh | bash
```

### Option 2: Local Build
If you have Go installed in Termux, you can build it yourself:
```bash
./build.sh
./install.sh
```

## Usage

1. **Start the daemon:**
   Run the helper script created during installation:
   ```bash
   tailscaled-start
   ```
   *Note: By default, this starts the daemon in the background with a random SOCKS5 port.*

2. **Authenticate:**
   ```bash
   tailscale-cli up
   ```

3. **Check status/test:**
   ```bash
   tailscale-test
   ```

## Configuration (.env)
You can configure the daemon by creating a file at `~/.tailscale/.env`. The `tailscaled-start` script will automatically load these variables:

| Variable | Tailscaled Flag | Description |
|----------|-----------------|-------------|
| `TS_SOCKS5_PORT` | `--socks5-server` | Set a specific port (e.g. `9050`) |
| `TS_SOCKS5_SERVER` | `--socks5-server` | Full address (e.g. `localhost:1055`) |
| `TS_HTTP_PROXY` | `--outbound-http-proxy-listen` | HTTP Proxy address |
| `TS_PORT` | `--port` | UDP port for WireGuard |
| `TS_DEBUG` | `--debug` | Debug server address |
| `TS_VERBOSE` | `--verbose` | Verbosity level (1, 2...) |
| `TS_NO_LOGS` | `--no-logs-no-support` | Set to `true` to disable logs |
| `TS_EXTRA_ARGS` | (raw flags) | Any other flags to pass |

Example `.env`:
```bash
TS_SOCKS5_PORT=1055
TS_VERBOSE=1
TS_EXTRA_ARGS="--hostname=termux-node"
```

## Helper Commands
- `tailscaled-start`: Starts the daemon with your config.
- `tailscaled-stop`: Stops the running daemon.
- `tailscaled-log`: Follows the daemon logs.
- `tailscale-cli`: Alias for `tailscale` that uses the correct socket.
- `tailscale-test`: Runs a functional test of your setup.

## Credits & Attribution
- **Core Logic:** [Tailscale Team](https://github.com/tailscale/tailscale).
- **Patch Inspiration:** [asutorufa/tailscale](https://github.com/Asutorufa/tailscale).
- **Architect & AI Assistance:** This project was developed with the assistance of the Gemini CLI AI Agent.

*Note: This project is not affiliated with Tailscale Inc.*
