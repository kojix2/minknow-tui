#!/usr/bin/env bash
set -euo pipefail
test_work=$(mktemp -d)
trap 'rm -rf "$test_work"' EXIT
mkdir -p "$test_work/repo/"{src,spec,lib,tools} "$test_work/bin" "$test_work/shard/src"
cp "$(dirname "${BASH_SOURCE[0]}")/../tools/test.sh" "$test_work/repo/tools/test.sh"
ln -s "$test_work/shard" "$test_work/repo/lib/example"
ln -s "$test_work/repo/lib" "$test_work/shard/lib"
printf 'version: 0.0.0\n' > "$test_work/repo/shard.yml"
touch "$test_work/repo/shard.lock" "$test_work/repo/src/main.cr" \
  "$test_work/repo/spec/first_spec.cr" "$test_work/shard/src/example.cr"
cat > "$test_work/bin/crystal" <<'CRYSTAL'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == --version ]]; then echo "test compiler ${TEST_COMPILER_VERSION:-1}"; exit; fi
echo build >> "$TEST_RECORD/builds"
if [[ "${TEST_COMPILE_FAIL:-0}" == 1 ]]; then exit 1; fi
while [[ "$1" != -o ]]; do shift; done
cat > "$2" <<'RUNNER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_RECORD/runs"
RUNNER
chmod +x "$2"
CRYSTAL
chmod +x "$test_work/bin/crystal"
export PATH="$test_work/bin:$PATH" TEST_RECORD="$test_work"
export CRYSTAL_CACHE_DIR="$test_work/compiler-cache"
cd "$test_work/repo"
count_builds() { test "$(wc -l < "$TEST_RECORD/builds" | tr -d ' ')" = "$1"; }
run_specs() {
  if ! bash tools/test.sh "$@" > "$TEST_RECORD/output" 2>&1; then
    cat "$TEST_RECORD/output" >&2
    return 1
  fi
}
run_specs --example first
count_builds 1
run_specs --example second
count_builds 1
tail -1 "$TEST_RECORD/runs" | grep -qx -- '--example second'
echo change >> src/main.cr
run_specs
count_builds 2
echo change >> lib/example/src/example.cr
run_specs
count_builds 3
mkdir spec/nested
touch spec/nested/new_spec.cr
run_specs
count_builds 4
grep -qx 'require "../spec/nested/new_spec.cr"' .ci-cache/test_runner.cr
export TEST_COMPILER_VERSION=2
run_specs
count_builds 5
run_specs --rebuild
count_builds 6
echo another_change >> src/main.cr
before=$(wc -l < "$TEST_RECORD/runs")
if TEST_COMPILE_FAIL=1 bash tools/test.sh > "$TEST_RECORD/expected-failure" 2>&1; then
  echo 'A failed compilation must fail the check' >&2; exit 1
fi
test "$(wc -l < "$TEST_RECORD/runs")" = "$before"
echo 'Test runner cache checks passed'
