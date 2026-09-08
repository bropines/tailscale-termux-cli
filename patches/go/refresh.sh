#!/usr/bin/env bash
# Re-vendor Termux's Go patches from termux-packages.
set -euo pipefail
cd "$(dirname "$0")"
REPO=termux/termux-packages
COMMIT=$(gh api "repos/$REPO/commits/master" -q '.sha')
for f in fix-hardcoded-etc-resolv-conf fix-android-netlink remove-pidfd remove-futex_time64; do
    gh api "repos/$REPO/contents/packages/golang/patch-script/$f.diff?ref=$COMMIT" -q '.content' \
        | base64 -d > "$f.diff"
    echo "updated $f.diff"
done
sed -i "s|^Taken at commit: .*|Taken at commit: $COMMIT|" README.md
echo "Now rebuild and re-test: the patches are sensitive to the Go version."
