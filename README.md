# Tailscale Termux CLI (Android 11+ Ready)

This project provides a patched version of the official Tailscale CLI (`tailscale` and `tailscaled`) designed specifically to run inside **Termux** on Android 11 and above without requiring Root or `/dev/net/tun`.

---

## 🚀 Quick Start (Easiest Installation)

Run this single command in Termux to download and install the latest package:

```bash
curl -fsSL https://raw.githubusercontent.com/bropines/tailscale-termux-cli/main/remote-install.sh | bash
```

The installer detects whether your Termux uses **dpkg** or **pacman** and fetches the matching package (`.deb` or `.pkg.tar.xz`). Releases carry a `SHA256SUMS` file if you want to verify the download by hand.

Once installed, the `tailscaled` background service is enabled and started. You can immediately connect:

```bash
tailscale up
```
*(or `tailscale-cli up`)*

---

## ✨ Features & Patches

1. **Netmon Bypass (Android 11+)**: Intercepts interface discovery (`anet` ioctl, `/proc/net/if_inet6`, `ifconfig` fallback) to bypass Android netlink restrictions.
2. **Userspace Networking**: Runs without Root or `/dev/net/tun` out of the box.
3. **Automatic Socket Resolution**: Both `tailscale` and `tailscale-cli` route requests to `~/.tailscale/tailscaled.sock` without a manual `--socket` flag.
4. **Auto-Start Daemon**: Invoking `tailscale` or `tailscale-cli` starts `tailscaled` if it is not running.
5. **Runit (`termux-services`) Integration**: Background service management, started when a Termux session opens.
6. **Authenticated SOCKS5 proxy**: credentials are generated for you on first start — see below.

---

## 🔐 The SOCKS5 Proxy (read this once)

`tailscaled` runs a SOCKS5 proxy on `127.0.0.1:1055` so you can route other apps through your tailnet.

**Android's loopback interface is not isolated per app.** Any app on the device holding only the `INTERNET` permission can connect to `127.0.0.1:1055`. If the proxy were open, that app would get egress into your tailnet *as this node* — reaching private hosts, subnet routes and your exit node.

So the proxy requires a username and password. They are generated on the first daemon start and stored in `~/.tailscale/socks5.env` (mode `0600`). Show them with:

```bash
tailscale-socks5
```

```
Tailscale SOCKS5 Proxy
======================
Address  : 127.0.0.1:1055   (running daemon)
Username : termux
Password : 5f3a9c1e8b7d2046
URL      : socks5://termux:5f3a9c1e8b7d2046@127.0.0.1:1055
```

Other useful forms:

| Command | Purpose |
|---|---|
| `tailscale-socks5` | Show address and credentials |
| `tailscale-socks5 --url` | Print just the proxy URL, for scripts |
| `tailscale-socks5 --regenerate` | Issue a new password (restart the daemon to apply) |

The credentials are passed to the daemon through its environment, never as command-line flags — anything on `argv` is readable by every process on the device via `/proc`.

To turn the proxy off entirely, set `TS_SOCKS5=off` in `~/.tailscale/.env`.

> [!WARNING]
> `TS_SOCKS5_NO_AUTH=1` restores the old unauthenticated proxy. It exists only for clients that cannot send SOCKS5 credentials, and it reopens your tailnet to every app on the device.

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
* **Show the SOCKS5 proxy credentials**:
  ```bash
  tailscale-socks5
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
* **Enable auto-start & start daemon**:
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

> [!NOTE]
> "Auto-start" means **when a Termux session opens**, not at device boot. `termux-services` starts its supervisor from `$PREFIX/etc/profile.d/start-services.sh`, so after a reboot the node stays offline until you open Termux. To get closer to real boot start, install the [Termux:Boot](https://wiki.termux.com/wiki/Termux:Boot) add-on, and consider `termux-wake-lock` so Android does not doze the daemon.

---

## 🔧 Configuration (`.env`)

Configure the daemon by creating/editing `~/.tailscale/.env`. It is read on **both** start paths — the `termux-services` service and a manual `tailscaled-start`.

| Variable | Effect | Description |
|----------|--------|-------------|
| `TS_SOCKS5_PORT` | `--socks5-server` | SOCKS5 port on `127.0.0.1` (default `1055`) |
| `TS_SOCKS5_SERVER` | `--socks5-server` | Full address (e.g. `127.0.0.1:1055`) |
| `TS_SOCKS5` | — | Set to `off` to disable the proxy entirely |
| `TS_SOCKS5_USER` / `TS_SOCKS5_PASS` | proxy credentials | Override the generated pair |
| `TS_SOCKS5_NO_AUTH` | proxy credentials | `1` disables proxy authentication (**not recommended**) |
| `TS_HTTP_PROXY` | `--outbound-http-proxy-listen` | HTTP proxy address |
| `TS_PORT` | `--port` | UDP port for WireGuard |
| `TS_DNS_SERVER` | resolver | Resolver to use (default `8.8.8.8`); `system` keeps Go's default |
| `TS_LOG_VERBOSITY` | log verbosity | `1`, `2`… (`TS_VERBOSE` is accepted as an alias) |
| `TS_NO_LOGS_NO_SUPPORT` | log upload | `true` disables log upload to Tailscale (`TS_NO_LOGS` is an alias) |
| `TS_EXTRA_ARGS` | (raw flags) | Additional raw flags to pass |

Example `~/.tailscale/.env`:
```bash
TS_SOCKS5_PORT=1055
TS_LOG_VERBOSITY=1
TS_EXTRA_ARGS="--hostname=termux-node"
```

Changes apply on the next daemon restart (`sv restart tailscaled`, or `tailscaled-stop && tailscaled-start`).

---

## 🔍 What the patches change about your node

Worth knowing before you put this on a tailnet you do not own:

* **DNS**: the binaries are built with `CGO_ENABLED=0`, so Go uses its pure-Go resolver, which wants `/etc/resolv.conf` — a file Termux does not have. The patch therefore points the resolver at `8.8.8.8:53`, meaning the daemon's lookups go to Google rather than your network's DNS. Change it with `TS_DNS_SERVER`, or set `TS_DNS_SERVER=system` to opt out.
* **Reported identity**: the daemon reports itself to the control plane as `App=tailscale-cli`, `DeviceModel=Termux`. This avoids mobile-specific client policies. Tailnet admins relying on client type for posture rules should know this node reports as a CLI client.

---

## 🏗️ Local Building

If you have Go installed in Termux, you can build from source:

```bash
./install.sh
```

`install.sh` produces both a `.deb` and a `.pkg.tar.xz` in `dist/`.

Two build-time guards worth knowing about:

* **The upstream tarball is checksummed.** `checksums/<version>.sha256` pins the SHA-256 of Tailscale's source archive, verified before anything is unpacked, compiled or run. A version with no pin yet is recorded and reported so you can commit it; set `TS_REQUIRE_CHECKSUM=1` to make an unpinned version a hard failure instead.
* **The binary is checked for the patches.** After every compile `build.sh` greps `tailscaled` for the netmon, `anet` and SOCKS5-auth markers and fails if any are missing. A `//go:build` tag that stops matching produces no warning anywhere, which is exactly how three architectures once shipped unpatched.

> [!NOTE]
> Only `aarch64` is built as `GOOS=android`; Go requires cgo/NDK external linking for every other Android architecture, so `arm`, `i686` and `x86_64` are built as static `GOOS=linux` binaries. The patches are tagged `android || linux` so they are present in all four.

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
<summary><b>2. My SOCKS5 client stopped working after an update</b></summary>
<br>
The proxy now requires a password. Get it with:

```bash
tailscale-socks5
```

and add the username/password to your client, or use the printed
`socks5://user:pass@host:port` URL directly.
</details>

<details>
<summary><b>3. Shell Autocompletions not working</b></summary>
<br>
Autocompletions for **Bash**, **Zsh**, and **Fish** are installed automatically. Restart your shell session or reload your shell profile to apply them.
</details>

---

## Credits & Contributors
- **Core Logic:** [Tailscale Team](https://github.com/tailscale/tailscale).
- **IPv6 UDP Probing & Netmon Enhancements:** [@sailshen](https://github.com/sailshen) (PR #8).
- **Patch Inspiration:** [asutorufa/tailscale](https://github.com/Asutorufa/tailscale).

The `tailscale` and `tailscaled` binaries are built from Tailscale's BSD-3-Clause source; the full notice ships in the package at `$PREFIX/share/doc/tailscale-termux/copyright`.

*Note: This project is not affiliated with Tailscale Inc.*
