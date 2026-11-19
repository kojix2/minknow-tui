#!/usr/bin/env bash
set -euo pipefail
test_work=$(mktemp -d)
trap 'rm -rf "$test_work"' EXIT
mkdir -p "$test_work/repo/tools" "$test_work/bin" "$test_work/existing-cache"
cp "$(dirname "${BASH_SOURCE[0]}")/../tools/test.sh" "$test_work/repo/tools/test.sh"
printf 'keep\n' > "$test_work/existing-cache/sentinel"
cat > "$test_work/bin/crystal" <<'CRYSTAL'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = spec
test "$2" = -Dwithout_readline
test "$3" = --stats
test "$4" = --
printf '%s\n' "$*" >> "$TEST_RECORD/runs"
printf '%s\n' "$CRYSTAL_CACHE_DIR" >> "$TEST_RECORD/caches"
mkdir -p "$CRYSTAL_CACHE_DIR"
touch "$CRYSTAL_CACHE_DIR/generated.o"
if [[ "${TEST_COMPILE_FAIL:-0}" == 1 ]]; then exit 1; fi
CRYSTAL
chmod +x "$test_work/bin/crystal"
export PATH="$test_work/bin:$PATH" TEST_RECORD="$test_work"
export CRYSTAL_CACHE_DIR="$test_work/existing-cache"
cd "$test_work/repo"

bash tools/test.sh --example 'first example'
bash tools/test.sh --order random
test "$(wc -l < "$TEST_RECORD/runs" | tr -d ' ')" = 2
grep -qx 'spec -Dwithout_readline --stats -- --example first example' "$TEST_RECORD/runs"
grep -qx 'spec -Dwithout_readline --stats -- --order random' "$TEST_RECORD/runs"
if TEST_COMPILE_FAIL=1 bash tools/test.sh; then
  echo 'A failed compilation must fail the check' >&2; exit 1
fi
test "$(sort -u "$TEST_RECORD/caches" | wc -l | tr -d ' ')" = 3
while IFS= read -r cache; do
  test "$cache" != "$CRYSTAL_CACHE_DIR"
  test ! -e "$cache"
done < "$TEST_RECORD/caches"
test -f "$CRYSTAL_CACHE_DIR/sentinel"
test ! -e .ci-cache
echo 'Fresh test compilation and temporary-cache cleanup checks passed'
