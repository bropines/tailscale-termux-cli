#!/usr/bin/env bash
# Regenerate the termux-packages patch files from patches/*.go.
#
# termux-packages applies `*.patch` files with `patch -p1`, so the added-file
# patches here have to be kept in step with the real sources in patches/.
# Running this script is how; do not hand-edit the generated .patch files.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="termux-packages/tailscale"
mkdir -p "$OUT"

# $1 = source file in patches/, $2 = destination inside the tailscale tree,
# $3 = output patch name
emit() {
    local src="$1" dst="$2" out="$OUT/$3"
    {
        printf 'Add %s\n' "$dst"
        printf '\n'
        printf 'Generated from %s by termux-packages/generate-patches.sh.\n' "$src"
        printf '\n'
        printf -- '--- /dev/null\n'
        printf -- '+++ b/%s\n' "$dst"
        printf '@@ -0,0 +1,%d @@\n' "$(wc -l < "$src")"
        # sed, not a command substitution: $(cat file) strips trailing
        # newlines, which silently produces a patch whose applied result does
        # not byte-match the source.
        sed 's/^/+/' "$src"
    } > "$out"
    echo "  wrote $out ($(wc -l < "$src") lines)"
}

emit patches/fix_android_netmon.go cmd/tailscaled/fix_android_netmon.go 0001-add-android-netmon-patch.patch
emit patches/fix_args_android.go   cmd/tailscaled/fix_args_android.go   0002-add-android-args-patch-tailscaled.patch
emit patches/fix_args_android.go   cmd/tailscale/fix_args_android.go    0003-add-android-args-patch-tailscale.patch

echo "Done. Verify with: patch -p1 --dry-run -d <tailscale-src> < $OUT/0001-*.patch"
