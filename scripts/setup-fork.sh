#!/usr/bin/env bash
# Rebuilds the editable fork: upstream BitChord at TAG + patches/*.patch as commits on branch `personal`.
# Usage: scripts/setup-fork.sh [TAG] [DIR]   (defaults: tag in patches/BASE, ../fork)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tag=${1:-$(cat "$here/patches/BASE")}
dir=${2:-$here/../fork}

if [ ! -d "$dir/.git" ]; then
  git clone --filter=blob:none https://github.com/kushagrasinghx/BitChord.git "$dir"
fi
cd "$dir"
git fetch --tags origin "refs/tags/$tag:refs/tags/$tag"
git checkout -B personal "refs/tags/$tag"
git config rerere.enabled true
git am --3way "$here"/patches/*.patch
echo "Branch 'personal' in $dir = $tag + $(git rev-list --count "refs/tags/$tag"..personal) patches"
