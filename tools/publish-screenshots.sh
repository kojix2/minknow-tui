#!/usr/bin/env bash
set -euo pipefail
captures_dir=$(cd "${1:?Usage: publish-screenshots.sh CAPTURE_DIR [REMOTE]}" && pwd)
remote=${2:-$(git remote get-url origin)}
branch=screenshots
# Check the main gallery before touching the destination branch.
for size in 120x36 80x24; do
  for screen in overview yield quality device pores activity; do
    test -s "$captures_dir/$size-$screen.png"
  done
done
test -s "$captures_dir/README.md"
test -s "$captures_dir/SOURCE.txt"
source_sha=$(cat "$captures_dir/SOURCE.txt")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git init -q "$work"
git -C "$work" remote add origin "$remote"
git -C "$work" config user.name 'github-actions[bot]'
git -C "$work" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
if git -C "$work" ls-remote --exit-code --heads origin "refs/heads/$branch" > /dev/null; then
  git -C "$work" fetch -q --depth=1 origin "refs/heads/$branch"
  git -C "$work" checkout -q -b "$branch" FETCH_HEAD
else
  status=$?
  if [[ "$status" != 2 ]]; then exit "$status"; fi
  # A new repository has no source-history parent: the first commit is orphaned.
  git -C "$work" symbolic-ref HEAD "refs/heads/$branch"
fi
git -C "$work" rm -q -r --ignore-unmatch .
cp "$captures_dir/"*.png "$captures_dir/README.md" "$captures_dir/SOURCE.txt" "$work/"
git -C "$work" add --all
if git -C "$work" diff --cached --quiet; then
  echo 'Screenshots are unchanged.'
  exit 0
fi
git -C "$work" commit -q -m "Update demo screenshots for $source_sha"
# Preserve branch history and reject concurrent updates instead of force-pushing.
git -C "$work" push origin "HEAD:refs/heads/$branch"
