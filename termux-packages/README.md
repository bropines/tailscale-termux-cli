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
`arm`, `i686`, `x86_64` — because the whole point of the netmon patch is that
it must be present in every one of them. Termux's own CI builds each
architecture, so a break shows up there too, but not until review.

## How this differs from the packages this repository publishes

Deliberately smaller. A distribution package should stay close to upstream and
leave policy to the user, so the extras this project ships are **not** here:

| Not included | Why |
|---|---|
| SOCKS5 authentication patch | The service starts no proxy at all, so there is nothing to protect. A user who enables `--socks5-server` gets upstream's behaviour, and `tailscaled.conf` spells out what that means on Android. |
| `tailscale-cli`, `tailscaled-start`, `tailscale-socks5`, … | Convenience wrappers, not something a distribution package should own. `sv up tailscaled` and plain `tailscale` cover it. |
| Generated credentials, `.env` loading, `tailscale-update` | Same reason. `tailscale-update` in particular has no business in a package that `pkg upgrade` maintains. |
| Pinned DNS resolver | Only needed because this project builds with `CGO_ENABLED=0`. Termux builds with cgo, so the system resolver works and no override is warranted. |

What *is* included is the part that is genuinely required to run at all on
Android 11+: the netmon patch and the socket-path patch.

## One real advantage of building inside termux-packages

This repository builds `aarch64` as `GOOS=android` and the other three as
`GOOS=linux`, because Go requires external (cgo) linking for every Android
target except `arm64` and shipping an NDK here is not worth it. The patches
are tagged `android || linux` to survive that.

termux-packages already has the NDK toolchain, so `build.sh` here sets
`GOOS=android` with `CGO_ENABLED=1` for all four architectures — the
straightforwardly correct build, with real Android binaries throughout.

## Keeping the patches in sync

`000*.patch` are generated. Edit `../patches/*.go` and re-run:

```bash
./termux-packages/generate-patches.sh
```

Verify they still apply before submitting:

```bash
curl -fsSL https://github.com/tailscale/tailscale/archive/refs/tags/v1.100.0.tar.gz | tar -xz
for p in termux-packages/tailscale/000*.patch; do
    patch -p1 --dry-run -d tailscale-1.100.0 < "$p"
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
