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
