#!/usr/bin/env bash
#
# mayhem/test.sh — RUN symbolic's own functional test suite for the two crates we
# fuzz (symbolic-debuginfo, symbolic-ppdb), already compiled by mayhem/build.sh.
# These suites assert concrete parsed values (e.g. test_objects.rs::test_wasm_symbols
# asserts Object::parse(wasm/simple.wasm).debug_id() ==
# "bda18fd8-5d4a-4eb8-9302-2d6bfad846b1" and .code_id() ==
# "bda18fd85d4a4eb893022d6bfad846b1"; test_caches.rs / test_ppdb.rs assert exact
# PortablePdbCache/PortablePdb field values) — a behavioral oracle, not exit-code-only.
# Emits a CTRF summary; exits non-zero iff failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

LOG="$(mktemp)"
env -u RUSTFLAGS cargo test -p symbolic-debuginfo -p symbolic-ppdb 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

# Sum every per-binary "test result: ok. P passed; F failed; I ignored; ..." line.
read -r P F S N < <(awk '
  /^test result:/ {
    for (i = 1; i <= NF; i++) {
      if ($(i+1) ~ /^passed/)  p += $i
      if ($(i+1) ~ /^failed/)  f += $i
      if ($(i+1) ~ /^ignored/) s += $i
    }
    n++
  }
  END { printf "%d %d %d %d\n", p, f, s, n }' "$LOG")
rm -f "$LOG"

# Behavioral guards: the suite must actually have RUN tests and passed some.
# A neutered cargo/test binary (exit 0, no output) yields N==0 or P==0 -> FAIL.
if [ "$N" -eq 0 ] || [ "$P" -eq 0 ]; then
  echo "ERROR: no test results parsed (suite did not run) — failing" >&2
  emit_ctrf "cargo-test" 0 1 0
  exit 1
fi
if [ "$rc" -ne 0 ] && [ "$F" -eq 0 ]; then
  F=1   # cargo test failed without a parsed failure count — count it
fi

emit_ctrf "cargo-test" "$P" "$F" "$S"
