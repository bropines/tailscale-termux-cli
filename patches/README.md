# What this project still patches, and what it stopped needing

Tailscale 1.104.0 absorbed most of what used to live here (see the top of the
[main README](../README.md)). This is the current inventory, kept here because
"why is this patch still here" is the question a reader of a patch directory
actually has.

## Still needed

* **`fix_socks5_auth.go`** — upstream's `socks5.Server` has `Username` and
  `Password` fields that `cmd/tailscaled` never sets, verified again in 1.104.0.
  Android's loopback is not per-app isolated, so an unauthenticated proxy on
  `127.0.0.1:1055` is reachable by any app holding `INTERNET`. `build.sh` seds
  the two fields into the server literal and fails the build if the sed misses.

* **`go/fix-android-netlink.diff`** — the one remaining patch with measured
  value. Upstream's `feature/androidbin` reports a single synthetic interface
  built from the default route's source address; this enumerates the real list.
  [The numbers](go/README.md#what-this-is-actually-worth) are in the toolchain
  patch notes. Note that it patches *Go*, not Tailscale.

* **`fix_hostinfo_android.go`** — reports `App=tailscale-cli`,
  `DeviceModel=Termux` so tailnet policies keyed on client type do not treat
  this as a phone app, and names an otherwise-`localhost` node
  `tailscale-termux`. A deliberate behavioural choice, not a workaround, and
  documented in the README because tailnet admins can see it.

* **`fix_args_android.go`**, the argv half — drops a duplicated `argv[1]` that
  some Termux configurations pass.

## No longer load-bearing, kept as a fallback

* **`go/fix-hardcoded-etc-resolv-conf.diff`** — `feature/androiddns` resolves
  through Android's `dnsproxyd` socket and sets `net.DefaultResolver.Dial`,
  which overrides whatever nameservers Go's config found, so this patch's
  redirect is not what resolves names any more. Proof: a 1.104.0 binary built
  with an *unpatched* toolchain resolves fine in Termux, which stock Go cannot
  do. It stays because `androiddns` stands down when the dnsproxyd socket does
  not answer, and then this is what keeps DNS working.

* **`fix_args_android.go`**, the socket half — 1.104.0 made the default socket
  path absolute on Android (`$TMPDIR/tailscaled.sock`), so the CLI and daemon
  now agree without help. This keeps the path at
  `~/.tailscale/tailscaled.sock` instead, next to the state directory and not
  in a directory Termux clears. Changing it would break every user's muscle
  memory for no gain, so it stays.

* **`go/remove-pidfd.diff`, `go/remove-futex_time64.diff`** — for Android
  kernels without those syscalls. Nothing here depends on them; they are part
  of what Termux applies and are kept so a build matches Termux's own.

## Gone

* **`fix_android_netmon.go`** — ~470 lines of `ifconfig` parsing,
  `/proc/net/if_inet6` reading and UDPv6 probing. Replaced by the toolchain
  patches, which also see cellular interfaces and global IPv6 that it missed.
* **The DNS default** — the daemon used to be started with `--dns=8.8.8.8`.
* **`github.com/wlynxg/anet` and `-ldflags=-checklinkname=0`** — the old netmon
  patch imported `anet`, which needs `//go:linkname` into the standard library
  and so needed the link-name check disabled. Nothing imports it now, and an
  `arm64` build with the check back on links clean, so both are gone.
