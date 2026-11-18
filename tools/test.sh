#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"

export CRYSTAL_CACHE_DIR="${CRYSTAL_CACHE_DIR:-$repo/.ci-cache/crystal}"
binary="$repo/.ci-cache/bin/spec"
mkdir -p "$(dirname "$binary")" "$CRYSTAL_CACHE_DIR"
rebuild=false
if [[ "${1:-}" == --rebuild ]]; then rebuild=true; shift; fi

if command -v sha256sum >/dev/null; then
  hash_command=(sha256sum)
else
  hash_command=(shasum -a 256)
fi
fingerprint_input=$(mktemp)
trap 'rm -f "$fingerprint_input"' EXIT
{
  crystal --version
  uname -sm
  printf '%s\n' '-Dwithout_readline' "${CI_TOOLCHAIN_KEY:-}" \
    "${CRYSTAL_PATH:-}" "${CRYSTAL_LIBRARY_PATH:-}" "${PKG_CONFIG_PATH:-}"
  "${hash_command[@]}" shard.yml shard.lock tools/test.sh
  # Follow top-level development shards, not their lib -> .. back-links.
  find -H src spec lib/* -name .git -prune -o -type f \( -name '*.cr' -o -name shard.yml \) -print0 |
    xargs -0 "${hash_command[@]}" | LC_ALL=C sort
} > "$fingerprint_input"
fingerprint=$("${hash_command[@]}" "$fingerprint_input" | cut -d ' ' -f 1)
if $rebuild || [[ ! -x "$binary" || ! -f "$binary.sha256" ]] ||
    [[ $(cat "$binary.sha256") != "$fingerprint" ]]; then
  echo 'Compiling test executable'
  runner="$repo/.ci-cache/test_runner.cr"
  find spec -type f -name '*_spec.cr' | LC_ALL=C sort | while IFS= read -r file; do
    printf 'require "../%s"\n' "$file"
  done > "$runner"
  [[ -s "$runner" ]] || { echo 'No specs found' >&2; exit 1; }
  crystal build "$runner" -Dwithout_readline --stats -o "$binary"
  printf '%s\n' "$fingerprint" > "$binary.sha256"
else
  echo 'Reusing unchanged test executable'
fi
"$binary" "$@"
