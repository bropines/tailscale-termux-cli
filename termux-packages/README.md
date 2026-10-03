# termux-packages submission

Everything needed to propose `tailscale` for the official [termux-packages][tp]
repository. Termux has no tailscale package today (checked against the full
repository tree: no `packages/tailscale`, and no match for "tailscale" among
its ~14000 paths), so this would be a new package rather than a change to an
existing one.

[tp]: https://github.com/termux/termux-packages

## What is here

```
tailscale/
  build.sh                 the package recipe
  tailscaled.conf          $PREFIX/etc/tailscale/tailscaled.conf
  sv/tailscaled.run.in     runit service template
  000*.patch               the Android patches, as patch(1) input
generate-patches.sh        regenerates those .patch files from ../patches/*.go
```

## How to submit

```bash
git clone https://github.com/termux/termux-packages
cp -r termux-packages/tailscale termux-packages-clone/packages/tailscale
cd termux-packages-clone
./scripts/run-docker.sh ./build-package.sh -a aarch64 tailscale
```

Build all four architectures before opening the pull request — `aarch64`,
`arm`, `i686`, `x86_64`. Termux's own CI builds each one, so a break shows up
there too, but not until review.

## How this differs from the packages this repository publishes

Deliberately smaller. A distribution package should stay close to upstream and
leave policy to the user, so the extras this project ships are **not** here:

| Not included | Why |
|---|---|
| SOCKS5 authentication patch | The service starts no proxy at all, so there is nothing to protect. A user who enables `--socks5-server` gets upstream's behaviour, and `tailscaled.conf` spells out what that means on Android. |
| `tailscale-cli`, `tailscaled-start`, `tailscale-socks5`, … | Convenience wrappers, not something a distribution package should own. `sv up tailscaled` and plain `tailscale` cover it. |
| Generated credentials, `.env` loading, `tailscale-update` | Same reason. `tailscale-update` in particular has no business in a package that `pkg upgrade` maintains. |
| Pinned DNS resolver | Gone from this project too. Tailscale 1.104.0 resolves through Android's own resolver daemon (`feature/androiddns`), so there is nothing left to pin. |
| Interface-discovery and DNS patches | Not Tailscale's problem to solve twice. `feature/androidbin` and `feature/androiddns` ship upstream as of 1.104.0, and the Go toolchain Termux builds with already carries the netlink and `resolv.conf` fixes — which is a better fix than either, since it enumerates the real interface list. |

What is left is one small patch: the argv/socket one. Upstream made the default
socket path absolute on Android in 1.104.0, so even that is close to
unnecessary; it survives here only to drop a duplicated `argv[1]` that some
Termux configurations pass.

## One real advantage of building inside termux-packages

Go requires external (cgo) linking for every Android target except `arm64`, so
a `GOOS=android` build of the other three needs an NDK. This repository now
carries that itself — it downloads the NDK in CI and builds all four as
`GOOS=android` — but termux-packages has the toolchain set up already, so the
recipe here gets it for free, along with a Go toolchain that is patched for
Android out of the box instead of patched by hand at build time.

## Keeping the patches in sync

`000*.patch` are generated. Edit `../patches/*.go` and re-run:

```bash
./termux-packages/generate-patches.sh
```

Verify they still apply before submitting:

```bash
curl -fsSL https://github.com/tailscale/tailscale/archive/refs/tags/v1.104.0.tar.gz | tar -xz
for p in termux-packages/tailscale/000*.patch; do
    patch -p1 --dry-run -d tailscale-1.104.0 < "$p"
done
```

## Before opening the pull request

* Bump `TERMUX_PKG_VERSION` and `TERMUX_PKG_SHA256` to the Tailscale release
  you are submitting. `TERMUX_PKG_AUTO_UPDATE=true` lets Termux's bot follow
  upstream tags afterwards.
* Change `TERMUX_PKG_MAINTAINER` if you are not the one maintaining it.
* Read [CONTRIBUTING.md][c] in termux-packages; they have opinions about
  commit messages and package layout, and this recipe follows `packages/cloudflared`
  as its model for the service, `prerm` and `svlogger` conventions.

[c]: https://github.com/termux/termux-packages/blob/master/CONTRIBUTING.md
