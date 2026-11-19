#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export CRYSTAL_CACHE_DIR="$work/crystal"
# Recompile every run without release optimization or persistent compiler output.
crystal spec -Dwithout_readline --stats -- "$@"
