#!/usr/bin/env bash
# Print the release notes for a tag on stdout.
#
#     ./scripts/release-notes.sh <tag> [assets-file]
#
# assets-file is one asset name per line. In CI that is the directory about to
# be uploaded; to regenerate an old release it comes from the API:
#
#     gh release view v1.100.0-11 --json assets --jq '.assets[].name' > /tmp/a
#     ./scripts/release-notes.sh v1.100.0-11 /tmp/a | gh release edit v1.100.0-11 --notes-file -
#
# Release pages used to carry a fixed three-line blurb, identical on every
# release, which went stale -- it advertised a netmon patch for two releases
# after that patch was deleted. So nothing here is written by hand. The
# upstream version comes from the tag, the changes from git, and what is
# attached from the assets themselves, because that varied: pacman packages
# start at v1.102.3-2, signatures at v1.102.5-1, SHA256SUMS at v1.100.0-10.
# Claiming any of them on an older page would be a new kind of wrong.
#
# Needs the full history and all tags; a shallow CI checkout has neither, so
# the workflow sets fetch-depth: 0.
set -euo pipefail

TAG="${1:-}"
ASSETS_FILE="${2:-}"
REPO="${GITHUB_REPOSITORY:-bropines/tailscale-termux-cli}"
if [ -z "$TAG" ]; then
    echo "usage: $0 <tag> [assets-file]" >&2
    exit 2
fi

# This project's tags are "<upstream version>-<build number>", the build number
# counting rebuilds of one upstream release and absent on the first. So the
# upstream version is the tag with that suffix removed.
upstream_of() { printf '%s' "${1#v}" | sed -E 's/-[0-9]+$//'; }

UPSTREAM="$(upstream_of "$TAG")"

# What to diff against, and what to diff. On the nightly path the tag does not
# exist yet -- the release action creates it from the checked-out commit after
# this script runs -- so the range ends at HEAD and starts at the newest tag
# behind it.
#
# The previous release is the nearest tagged ancestor, which is what `git
# describe` answers. Picking the preceding tag out of a version-sorted list
# would be wrong whenever a rebuild of an older upstream release is tagged
# after a newer one, because then version order and history order disagree and
# the commit range comes out backwards or empty.
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    HEAD_REF="$TAG"
    # --exclude the tag itself rather than describing its parent: this project
    # has two tags on one commit more than once (the nightly tagged v1.102.4 on
    # the same commit as the hand-made v1.102.3-7), and describing the parent
    # skips over the sibling and re-lists changes that already shipped.
    PREV="$(git describe --tags --abbrev=0 --exclude="$TAG" "$TAG" 2>/dev/null || true)"
else
    HEAD_REF="HEAD"
    PREV="$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
fi

ASSETS=""
[ -n "$ASSETS_FILE" ] && [ -r "$ASSETS_FILE" ] && ASSETS="$(cat "$ASSETS_FILE")"
has() { printf '%s\n' "$ASSETS" | grep -q "$1"; }

printf 'Tailscale **%s** for Termux on Android 11+.\n\n' "$UPSTREAM"

if [ -n "$ASSETS" ]; then
    # paste -d takes a LIST of delimiters and cycles through them, so
    # -d', ' alternates comma and space. Join with commas, then space them.
    ARCHES="$(printf '%s\n' "$ASSETS" | sed -n 's/^tailscaled-\([a-z0-9_]*\)$/\1/p' | sort | sed 's/^/`/; s/$/`/' | paste -sd, - | sed 's/,/, /g')"
    if has '\.pkg\.tar\.xz$'; then
        printf 'Packages for %s, as `.deb` and for pacman, plus the loose binaries.\n\n' "${ARCHES:-the four architectures}"
    else
        printf '`.deb` packages for %s, plus the loose binaries.\n\n' "${ARCHES:-the four architectures}"
    fi
fi

printf 'What this build changes about stock Tailscale is in the [README](https://github.com/%s#readme).\n\n' "$REPO"

if [ -z "$PREV" ]; then
    printf '## Changes\n\nFirst tagged release.\n\n'
else
    PREV_UPSTREAM="$(upstream_of "$PREV")"
    printf '## Upstream Tailscale\n\n'
    if [ "$PREV_UPSTREAM" = "$UPSTREAM" ]; then
        printf 'Unchanged at %s — a rebuild of the same upstream release.\n\n' "$UPSTREAM"
    else
        printf '%s → **%s** ([upstream release notes](https://github.com/tailscale/tailscale/releases/tag/v%s))\n\n' \
            "$PREV_UPSTREAM" "$UPSTREAM" "$UPSTREAM"
    fi

    # Subjects only: the commit bodies here carry trailers and several
    # paragraphs each, which do not belong on a release page.
    COMMITS="$(git log --no-merges --reverse --pretty='- %s' "$PREV..$HEAD_REF" 2>/dev/null || true)"
    printf '## Changes in this repository\n\n'
    if [ -z "$COMMITS" ]; then
        if [ "$PREV_UPSTREAM" = "$UPSTREAM" ]; then
            # Not a link: some tags here never got a release page, so a
            # /releases/tag/ link built from a tag name can 404.
            printf 'None — rebuilt from the same commit as `%s`.\n\n' "$PREV"
        else
            printf 'None — only the upstream Tailscale version changed.\n\n'
        fi
    else
        printf '%s\n\n' "$COMMITS"
        printf '[Full diff](https://github.com/%s/compare/%s...%s)\n\n' "$REPO" "$PREV" "$TAG"
    fi
fi

printf '## Install\n\n'
printf 'The one-liner always installs the current release, whichever that is:\n\n'
printf '```\ncurl -fsSL https://raw.githubusercontent.com/%s/main/remote-install.sh | bash\n```\n\n' "$REPO"
printf 'It picks the right package for your Termux, dpkg or pacman, and verifies the download. Already installed? `tailscale-update`.\n' 

if [ -n "$ASSETS" ]; then
    if has '\.sig$'; then
        printf '\nThe pacman packages here carry a detached signature, from key `2D5133D5E2C7C8E7BE2D0CBB6EAA7CF6CEFB203E` (`tailscale-termux-cli.asc`, attached).\n'
    fi
    if has '^SHA256SUMS$'; then
        printf '\n`SHA256SUMS` covers every asset on this page.\n'
    fi
fi
