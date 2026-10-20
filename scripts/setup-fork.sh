#!/usr/bin/env bash
# Rebuilds the editable fork: upstream BitChord at TAG + patches/*.patch as commits on branch `personal`.
# Usage: scripts/setup-fork.sh [TAG] [DIR]   (defaults: tag in patches/BASE, ../fork)
# An existing branch `personal` is reset to the patches: export it first, then rerun with FORCE=1.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tag=${1:-$(cat "$here/patches/BASE")}
dir=${2:-$here/../fork}

git var GIT_COMMITTER_IDENT >/dev/null   # git am needs one: git config --global user.name / user.email
if [ ! -d "$dir/.git" ]; then
  git clone --filter=blob:none https://github.com/kushagrasinghx/BitChord.git "$dir"
fi
cd "$dir"
if git rev-parse -q --verify refs/heads/personal >/dev/null && [ "${FORCE:-}" != 1 ]; then
  echo "$dir already has branch 'personal'; commits not yet in patches/ would be lost." >&2
  echo "Run scripts/export-patches.sh first, or rerun with FORCE=1 to rebuild it from patches/." >&2
  exit 1
fi
git fetch --tags origin "refs/tags/$tag:refs/tags/$tag"
git checkout -B personal "refs/tags/$tag"
git config rerere.enabled true
git am --3way "$here"/patches/*.patch
echo "Branch 'personal' in $dir = $tag + $(git rev-list --count "refs/tags/$tag"..personal) patches"
