# Tailscale Termux CLI (Android 11+ Ready)

This project provides a patched version of the official Tailscale CLI (`tailscale` and `tailscaled`) designed specifically to run inside **Termux** on Android, even on versions 11 and above where system restrictions normally break it.

## 🏗 The Netmon Patch
On Android 11+ (API 30+), Google restricted access to `netlink`, which Tailscale uses to monitor network interfaces. This causes the official binary to fail with `permission denied`. 

Our patch (originally inspired by the work of [asutorufa](https://github.com/Asutorufa/tailscale)):
1. **Bypasses Netlink**: Intercepts the interface discovery process.
2. **Uses `ifconfig` Parser**: Executes and parses the output of `ifconfig` (which still works via `ioctl`) to find real IP addresses (Wi-Fi, Mobile Data, etc.).
3. **Userspace Networking**: Optimized to run without Root or `/dev/net/tun` by leveraging Tailscale's userspace networking engine.

## 🚀 Installation

### Option 1: Precompiled (Recommended)
Download the latest binaries from the **GitHub Actions** artifacts of this repository.

### Option 2: Build Locally (Inside Termux)
If you have Go installed in Termux, you can build it yourself:
```bash
./build.sh
```

## 🛠 Usage

1. **Copy binaries to your path:**
   ```bash
   mkdir -p ~/bin
   cp bin/tailscale* ~/bin/
   chmod +x ~/bin/tailscale*
   ```

2. **Start the daemon (Background):**
   ```bash
   mkdir -p ~/.tailscale
   ~/bin/tailscaled --statedir=~/.tailscale --tun=userspace-networking --socks5-server=localhost:1055 &
   ```

3. **Authenticate:**
   ```bash
   ~/bin/tailscale up
   ```

## 🤖 Termux Services (sv)
If you use `termux-services`, you can run the provided installer:
```bash
./install.sh
sv start tailscaled
```

## 📜 Credits
This is a patched version of the official [Tailscale](https://github.com/tailscale/tailscale) source code. All credit for the core logic goes to the Tailscale team. We just added the necessary bridges to make it play nice with Termux's unique environment, building upon ideas from [asutorufa/tailscale](https://github.com/Asutorufa/tailscale).

*Note: This project is not affiliated with Tailscale Inc.*
