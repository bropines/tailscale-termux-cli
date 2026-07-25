# Tailscale Termux CLI (Android 11+ Ready)

This project provides a patched version of the official Tailscale CLI (`tailscale` and `tailscaled`) designed specifically to run inside **Termux** on Android 11 and above without requiring Root or `/dev/net/tun`.

---

## 🚀 Quick Start (Easiest Installation)

Run this single command in Termux to download and install the latest package:

```bash
curl -fsSL https://raw.githubusercontent.com/bropines/tailscale-termux-cli/main/remote-install.sh | bash
```

Once installed, the `tailscaled` background service is automatically enabled and started. You can immediately connect:

```bash
tailscale up
```
*(or `tailscale-cli up`)*

---

## ✨ Features & Patches

1. **Netmon Bypass (Android 11+)**: Intercepts interface discovery using an `ifconfig` parser to bypass Android netlink restrictions.
2. **Userspace Networking**: Runs without Root or `/dev/net/tun` out of the box.
3. **Automatic Socket Resolution**: Both `tailscale` and `tailscale-cli` automatically route requests to `~/.tailscale/tailscaled.sock` without requiring manual `--socket` flags.
4. **Auto-Start Daemon**: Invoking `tailscale` or `tailscale-cli` automatically starts the `tailscaled` daemon if it is not currently running.
5. **Runit (`termux-services`) Integration**: Native background service management with auto-start on boot support.

---

## 🛠️ Usage & Commands

You can use standard `tailscale` commands or the `tailscale-cli` wrapper interchangeably.

> [!TIP]
> Subcommands like `tailscale funnel`, `tailscale serve`, `tailscale status`, and `tailscale ping` work natively out of the box!

### Common Commands

* **Connect / Log in**:
  ```bash
  tailscale up
  ```
* **Check connection status**:
  ```bash
  tailscale status
  ```
* **Expose a local service (Funnel / Serve)**:
  ```bash
  tailscale funnel 8096
  ```
* **Run functional test (SOCKS5 & DNS)**:
  ```bash
  tailscale-test
  ```

---

## ⚙️ Managing the Background Service

The background daemon is managed via `termux-services` (runit) or helper commands:

* **Check daemon status**:
  ```bash
  tailscaled-start --service=status
  ```
* **Enable auto-start on boot & start daemon**:
  ```bash
  tailscaled-start --service=on
  ```
* **Disable auto-start & stop daemon**:
  ```bash
  tailscaled-start --service=off
  ```
* **View daemon logs**:
  ```bash
  tailscaled-log
  ```

---

## 🔧 Configuration (`.env`)

Configure daemon settings by creating/editing `~/.tailscale/.env`. Variables are automatically loaded on start:

| Variable | Tailscaled Flag | Description |
|----------|-----------------|-------------|
| `TS_SOCKS5_PORT` | `--socks5-server` | Set a specific SOCKS5 port (e.g. `1055`) |
| `TS_SOCKS5_SERVER` | `--socks5-server` | Full address (e.g. `127.0.0.1:1055`) |
| `TS_HTTP_PROXY` | `--outbound-http-proxy-listen` | HTTP Proxy address |
| `TS_PORT` | `--port` | UDP port for WireGuard |
| `TS_VERBOSE` | `--verbose` | Log verbosity level (`1`, `2`...) |
| `TS_EXTRA_ARGS` | (raw flags) | Additional raw flags to pass |

Example `~/.tailscale/.env`:
```bash
TS_SOCKS5_PORT=1055
TS_VERBOSE=1
TS_EXTRA_ARGS="--hostname=termux-node"
```

---

## 🏗️ Local Building

If you have Go installed in Termux, you can build from source:

```bash
./build.sh
./install.sh
```

---

## 💡 Troubleshooting

<details>
<summary><b>1. "failed to connect to local tailscaled process"</b></summary>
<br>
If the daemon was stopped manually, start it using:

```bash
tailscaled-start
```
Or ensure termux-services is running:
```bash
sv up tailscaled
```
</details>

<details>
<summary><b>2. Shell Autocompletions not working</b></summary>
<br>
Autocompletions for **Bash**, **Zsh**, and **Fish** are installed automatically. Restart your shell session or reload your shell profile to apply them.
</details>

---

## Credits & Attribution
- **Core Logic:** [Tailscale Team](https://github.com/tailscale/tailscale).
- **Patch Inspiration:** [asutorufa/tailscale](https://github.com/Asutorufa/tailscale).

*Note: This project is not affiliated with Tailscale Inc.*

