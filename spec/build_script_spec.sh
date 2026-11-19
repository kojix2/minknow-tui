#!/usr/bin/env bash
# Exercise the real mode branches without compiling or downloading dependencies.
set -euo pipefail
test_work=$(mktemp -d)
trap 'rm -rf "$test_work"' EXIT
mkdir -p "$test_work/repo/"{.github/scripts,spec,tools} "$test_work/bin" "$test_work/native/lib"
cp "$(dirname "${BASH_SOURCE[0]}")/../.github/scripts/build.sh" "$test_work/repo/.github/scripts/build.sh"
cp "$(dirname "${BASH_SOURCE[0]}")/../tools/test.sh" "$test_work/repo/tools/test.sh"
touch "$test_work/native/lib/"{libnghttp2.a,libunibilium.a}
printf '1.71.0-Linux-x86_64\n' > "$test_work/native/.nghttp2-version"
printf '2.1.4-Linux-x86_64\n' > "$test_work/native/.unibilium-version"
touch "$test_work/repo/"{README.md,shard.yml,shard.lock}
cat > "$test_work/repo/spec/test_runner_spec.sh" <<'CHECK'
#!/usr/bin/env bash
printf 'checked\n' >> "$TEST_RECORD/shell-checks"
CHECK
cp "$test_work/repo/spec/test_runner_spec.sh" "$test_work/repo/spec/build_script_spec.sh"
cat > "$test_work/bin/uname" <<'UNAME'
#!/usr/bin/env bash
case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) exit 1 ;; esac
UNAME
cat > "$test_work/bin/shards" <<'SHARDS'
#!/usr/bin/env bash
case "$*" in 'install --frozen'|'--version') echo 'test shards' ;; *) exit 1 ;; esac
SHARDS
cat > "$test_work/bin/pkg-config" <<'PKG'
#!/usr/bin/env bash
echo 'test library version'
PKG
cat > "$test_work/bin/readelf" <<'ELF'
#!/usr/bin/env bash
echo 'Static ELF executable'
ELF
cat > "$test_work/bin/crystal" <<'CRYSTAL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_RECORD/compiler"
printf '%s\n' "$CRYSTAL_CACHE_DIR" >> "$TEST_RECORD/caches"
mkdir -p "$CRYSTAL_CACHE_DIR"
touch "$CRYSTAL_CACHE_DIR/generated.o"
case "$1" in
  tool|--version) exit 0 ;;
  spec)
    test "${TEST_SPEC_FAIL:-0}" != 1
    exit ;;
  build)
    while [[ "$1" != -o ]]; do shift; done
    cat > "$2" <<'BINARY'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  --version|--help) echo 'mock application' ;;
  --demo) printf 'LIVE X1\nPass yield:\n' > "$CRYSTERM_DUMP" ;;
  *) exit 1 ;;
esac
BINARY
    chmod +x "$2" ;;
  *) exit 1 ;;
esac
CRYSTAL
chmod +x "$test_work/bin/"*
export PATH="$test_work/bin:$PATH" TEST_RECORD="$test_work" CI_NATIVE_PREFIX="$test_work/native"
cd "$test_work/repo"

# With no mode specified, run checks and a non-release build, without packaging.
bash .github/scripts/build.sh > "$test_work/check.log"
grep -q '^spec ' "$TEST_RECORD/compiler"
grep -q '^build src/main.cr ' "$TEST_RECORD/compiler"
! grep -q -- '--release' "$TEST_RECORD/compiler"
test "$(wc -l < "$TEST_RECORD/shell-checks" | tr -d ' ')" = 2
test ! -e dist

# A failing spec blocks the ordinary application build.
: > "$TEST_RECORD/compiler"
if TEST_SPEC_FAIL=1 bash .github/scripts/build.sh check > "$test_work/fail.log"; then
  echo 'Failed specs must fail check mode' >&2; exit 1
fi
! grep -q '^build ' "$TEST_RECORD/compiler"

# Release mode must not invoke specs, formatting or shell checks.
: > "$TEST_RECORD/compiler"
rm "$TEST_RECORD/shell-checks"
TEST_SPEC_FAIL=1 bash .github/scripts/build.sh release > "$test_work/release.log"
! grep -Eq '^(spec|tool) ' "$TEST_RECORD/compiler"
test "$(grep -c '^build ' "$TEST_RECORD/compiler")" = 1
grep -Eq '^build src/main.cr .*--release' "$TEST_RECORD/compiler"
test ! -e "$TEST_RECORD/shell-checks"
test -s dist/minknow-tui-linux-x86_64.tar.gz
while IFS= read -r cache; do test ! -e "$cache"; done < "$TEST_RECORD/caches"
echo 'Check/release separation, failure propagation and temporary-cache cleanup checks passed'
