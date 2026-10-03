# Go toolchain patches (vendored from termux-packages)

These are Termux's own patches to the Go standard library, applied to the
toolchain before cross-compiling. They are what makes a Go binary behave on
Android the way Termux's own Go-built packages do:

* `fix-android-netlink.diff` — Android 11+ denies app UIDs `bind(2)` on netlink
  sockets, so `net.Interfaces()` fails with `netlinkrib: permission denied` and
  `netmon.New` errors out before anything runs. Falls back to an RTM_GETADDR
  dump plus SIOCGIF* ioctls, the same approach as github.com/wlynxg/anet.
* `fix-hardcoded-etc-resolv-conf.diff` — Android has no `/etc/resolv.conf`, so
  Go's pure resolver falls back to `[::1]:53` and every lookup fails. Points it
  at `$PREFIX/etc/resolv.conf`, which Termux ships and the user can edit.
* `remove-pidfd.diff`, `remove-futex_time64.diff` — syscalls unavailable on
  older Android kernels.

## What this is actually worth

Since Tailscale 1.104.0 these patches are no longer what makes the thing *run*
on a phone — `feature/androidbin` and `feature/androiddns` cover that upstream.
What they still buy is interface discovery, which upstream solves differently:
`androidbin` opens an outbound UDP socket per address family and reads back the
source address the kernel picked, yielding one synthetic interface named
`android`. Its own package comment says it "can't see the full multi-interface
picture".

Measured back to back in a single command on a Redmi (Android 16, non-root
Termux, Wi-Fi + LTE), both binaries built from tailscale v1.104.0, the only
difference being the toolchain:

    upstream Go   link state: ifs={android:[10.10.10.10/32]} v4=true v6=false
    patched Go    link state: ifs={rmnet_data11:[100.94.1.89/30]
                                   rmnet_data4:[10.125.148.57/30]
                                   rmnet_data7:[2a00:1fa0:5325:4162:...:2f2b/64]
                                   tun0:[10.10.10.10/32]
                                   wlan2:[10.186.245.248/24]} v4=true v6=true

Neither logged a netlink error. A later run against the real (logged-in) node
turned that into endpoints: 4 advertised with these patches, including the
global IPv6 and the Wi-Fi address, against 2 without — the public IPv4 and
`10.10.10.10`.

**Read that with two caveats, because the test device was not a clean one.**

* `tun0:[10.10.10.10/32]` is a third-party `VpnService`, and `dumpsys netstats`
  confirms it was the default network. So the single address `androidbin` found
  was that VPN's inner address, which is useless as an endpoint. With no other
  VPN running, the default route's source address *is* the Wi-Fi address, so the
  LAN endpoint would have survived and the gap would be smaller.
* The two runs above are from the same minute, but the endpoint comparison was
  taken hours later, after the phone had roamed to another network. Compare the
  interface sets, not the two sets of literal addresses.

What is true regardless of the VPN: `androidbin` reports **only the
default-route interface**, so a phone never advertises its other path — no
cellular IPv6 while on Wi-Fi, no Wi-Fi while on cellular — and when some other
app holds the default route, nothing real at all. That is the whole remaining
argument for patching the toolchain, and it would go away if upstream did the
enumeration the way these patches do: skip the `bind(2)` that Android denies and
dump `RTM_GETADDR` from an unbound socket.

Vendored rather than fetched at build time so a build does not depend on a
third-party repository staying reachable or unchanged.

Source: https://github.com/termux/termux-packages/tree/master/packages/golang/patch-script
Taken at commit: 09d7e9f4951a5bb64c3ec7a151940d8f244c1dc6
Applied cleanly to: go1.27.1

## Refreshing

    ./patches/go/refresh.sh

The patches are version-sensitive: they patch Go's own sources, so a Go upgrade
can break them. build.sh treats a failed application as fatal rather than
silently producing a binary without them.
