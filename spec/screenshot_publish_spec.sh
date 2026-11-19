#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_work=$(mktemp -d)
trap 'rm -rf "$test_work"' EXIT
git init -q --bare "$test_work/remote.git"
git init -q "$test_work/source"
git -C "$test_work/source" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m Source
git -C "$test_work/source" push -q "$test_work/remote.git" HEAD:refs/heads/main
source_sha=$(git -C "$test_work/source" rev-parse HEAD)
captures="$test_work/captures"
mkdir -p "$captures"
for size in 120x36 80x24; do
  for screen in overview yield quality device pores activity; do
    printf 'image %s %s\n' "$size" "$screen" > "$captures/$size-$screen.png"
  done
done
printf 'gallery\n' > "$captures/README.md"
printf '%s\n' "$source_sha" > "$captures/SOURCE.txt"
printf 'diagnostic text\n' > "$captures/120x36-overview.dump"
printf 'obsolete image\n' > "$captures/old.png"

# The first publication has no parent shared with main and includes only assets.
bash "$repo/tools/publish-screenshots.sh" "$captures" "$test_work/remote.git"
first=$(git --git-dir="$test_work/remote.git" rev-parse screenshots)
test "$(git --git-dir="$test_work/remote.git" rev-list --count screenshots)" = 1
test "$(git --git-dir="$test_work/remote.git" rev-parse main)" = "$source_sha"
test "$(git --git-dir="$test_work/remote.git" ls-tree --name-only screenshots | wc -l | tr -d ' ')" = 15
! git --git-dir="$test_work/remote.git" ls-tree --name-only screenshots | grep -q '\.dump$'
! git --git-dir="$test_work/remote.git" merge-base main screenshots

# Repeating an identical publication is a no-op.
bash "$repo/tools/publish-screenshots.sh" "$captures" "$test_work/remote.git"
test "$(git --git-dir="$test_work/remote.git" rev-parse screenshots)" = "$first"

# A normal update prunes removed images and keeps the existing parent.
rm "$captures/old.png"
printf 'updated image\n' > "$captures/120x36-overview.png"
bash "$repo/tools/publish-screenshots.sh" "$captures" "$test_work/remote.git"
test "$(git --git-dir="$test_work/remote.git" rev-parse screenshots^)" = "$first"
! git --git-dir="$test_work/remote.git" ls-tree --name-only screenshots | grep -qx old.png
test "$(git --git-dir="$test_work/remote.git" show screenshots:120x36-overview.png)" = 'updated image'
second=$(git --git-dir="$test_work/remote.git" rev-parse screenshots)

# Missing captures and an unreachable remote must not replace published assets.
rm "$captures/80x24-pores.png"
if bash "$repo/tools/publish-screenshots.sh" "$captures" "$test_work/remote.git"; then
  echo 'Incomplete captures must not be published' >&2; exit 1
fi
test "$(git --git-dir="$test_work/remote.git" rev-parse screenshots)" = "$second"
printf 'restored\n' > "$captures/80x24-pores.png"
if bash "$repo/tools/publish-screenshots.sh" "$captures" "$test_work/missing.git" > "$test_work/failure.log" 2>&1; then
  echo 'An inaccessible remote must fail publication' >&2; exit 1
fi
echo 'Screenshot orphan publication, updates and failure checks passed'
