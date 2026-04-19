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
   *Note: This starts the daemon in the background with userspace networking enabled.*

2. **Authenticate:**
   ```bash
   tailscale up
   ```

## Termux Services (sv)
If you have termux-services installed, the install.sh script will prompt you to set up tailscaled as a managed service. You can then manage it with:
```bash
sv start tailscaled
sv stop tailscaled
```

## Automated Updates
This repository automatically checks for new stable Tailscale releases every 24 hours. When a new version is detected, GitHub Actions will:
1. Create a new tag in this repository.
2. Build the patched binaries for Android/ARM64.
3. Create a new GitHub Release with the precompiled binaries.

## Credits & Attribution
- **Core Logic:** [Tailscale Team](https://github.com/tailscale/tailscale).
- **Patch Inspiration:** [asutorufa/tailscale](https://github.com/Asutorufa/tailscale).
- **Architect & AI Assistance:** This project was developed with the assistance of the Gemini CLI AI Agent, which designed the Netmon bridge and automated the build/release pipelines.

*Note: This project is not affiliated with Tailscale Inc.*
