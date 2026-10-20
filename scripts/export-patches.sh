#!/usr/bin/env bash
# Writes branch `personal` back out as patches/*.patch (+ patches/BASE). Commit and push to trigger CI.
# Usage: scripts/export-patches.sh [TAG] [DIR]   (defaults: tag in patches/BASE, ../fork)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tag=${1:-$(cat "$here/patches/BASE")}
dir=${2:-$here/../fork}

find "$here/patches" -name '*.patch' -delete
git -C "$dir" format-patch -q -o "$here/patches" --zero-commit --no-signature "refs/tags/$tag"..personal
echo "$tag" > "$here/patches/BASE"
echo "Exported $(ls "$here"/patches/*.patch | wc -l) patches on $tag"
