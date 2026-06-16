# Tailscale Termux CLI (Android 11+ Ready)

> [!WARNING]
> **Git History Rewrite**: The repository commit history was rewritten on May 24, 2026, to remove accidentally committed debug logs. If you have an existing clone, please run `git fetch origin && git reset --hard origin/main` to sync your local copy with the updated history.

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

1. **Start the daemon (manually):**
   Run the helper script created during installation:
   ```bash
   tailscaled-start
   ```
   *Note: By default, this starts the daemon in the background with a random SOCKS5 port.*

2. **Run as a persistent system service (via termux-services):**
   We package integration with `termux-services` (runit). You can manage the background service easily:
   * **Enable auto-start on boot & run service**:
     ```bash
     tailscaled-start --service=on
     ```
   * **Disable auto-start & stop service**:
     ```bash
     tailscaled-start --service=off
     ```
   * **Check service status**:
     ```bash
     tailscaled-start --service=status
     ```
   *(Alternatively, you can use standard commands: `sv-enable tailscaled`, `sv-disable tailscaled`, and `sv status tailscaled`).*

3. **Authenticate:**
   ```bash
   tailscale-cli up
   ```

4. **Check status/test:**
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
- `tailscaled-start`: Starts the daemon manually or controls its termux-service status (`--service=on/off/status`).
- `tailscaled-stop`: Stops the running daemon.
- `tailscaled-log`: Follows the daemon logs.
- `tailscale-cli`: Alias for `tailscale` that uses the correct socket.
- `tailscale-test`: Runs a functional test of your setup.

## Shell Integrations (Autocomplete)

The package automatically installs shell autocompletions for **Bash**, **Zsh**, and **Fish** for both the `tailscale` and `tailscale-cli` commands. Once installed, autocompletions will work natively after restarting your shell session.

## Credits & Attribution
- **Core Logic:** [Tailscale Team](https://github.com/tailscale/tailscale).
- **Patch Inspiration:** [asutorufa/tailscale](https://github.com/Asutorufa/tailscale).
- **Architect & AI Assistance:** This project was developed with the assistance of the Gemini CLI AI Agent.

*Note: This project is not affiliated with Tailscale Inc.*
