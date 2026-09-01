#!/usr/bin/env bash
#
# mayhem/build.sh — build symbolic's cargo-fuzz targets (upstream's OWN fuzz/ crates:
# symbolic-debuginfo/fuzz::fuzz_objects, symbolic-ppdb/fuzz::fuzz_ppdb) as sanitized
# libFuzzer binaries, plus pre-compile the upstream test suite (normal flags) so
# mayhem/test.sh only RUNS it.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
# Every dependency is resolved from the $CARGO_HOME registry cache this first
# (online) build populates; do NOT hard-code --offline (it would break this first,
# online build) — the rlenv runtime exports CARGO_NET_OFFLINE=true for the re-run.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# ── The upstream test suite, with the project's NORMAL flags (clean build) ────
# mayhem/test.sh re-runs this exact cargo invocation, hitting the build cache
# produced here. Scoped to the two crates we fuzz (+ their own dev-deps).
env -u RUSTFLAGS cargo test --no-run -p symbolic-debuginfo -p symbolic-ppdb

# ── The fuzz targets: OSS-Fuzz Rust libFuzzer+ASan path via cargo-fuzz ─────────
# $SANITIZER_FLAGS (clang flags from the base ENV) can't be fed to rustc directly;
# translate its intent: sanitizers ON (the default) → ASan via -Zsanitizer=address,
# an explicitly EMPTY SANITIZER_FLAGS → no sanitizer.
RUST_SAN="-Zsanitizer=address"
[ -z "${SANITIZER_FLAGS+x}" ] || [ -n "${SANITIZER_FLAGS}" ] || RUST_SAN=""
# DWARF <= 3 debug info for triage (SPEC §6.2 item 10) — threaded via RUST_DEBUG_FLAGS.
RUST_DEBUG_FLAGS="${RUST_DEBUG_FLAGS:--Cdebuginfo=1 -Zdwarf-version=3}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_SAN $RUST_DEBUG_FLAGS -Cforce-frame-pointers"
# The cc-built libFuzzer runtime honours CFLAGS/CXXFLAGS, and --build-std recompiles
# std with our RUSTFLAGS (the prebuilt std ships DWARF-4 debuginfo).
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"
# rustc's prebuilt sanitizer runtimes (compiler-rt) ship DWARF-5 CUs; strip their
# debug info so the linked fuzz binaries stay DWARF <= 3 (runtime frames are never
# triaged as project bugs). Idempotent: stripping a stripped archive is a no-op.
find "$RUSTUP_HOME"/toolchains/*/lib/rustlib/x86_64-unknown-linux-gnu/lib \
  -name 'librustc-*_rt.*.a' -exec objcopy --strip-debug {} \; 2>/dev/null || true

TRIPLE="x86_64-unknown-linux-gnu"

# The historical/chosen Mayhem target set: (fuzz-crate-dir, binary-name).
FUZZ_DIRS=(symbolic-debuginfo/fuzz symbolic-ppdb/fuzz)
FUZZ_TARGETS=(fuzz_objects fuzz_ppdb)

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for i in "${!FUZZ_TARGETS[@]}"; do
  d="${FUZZ_DIRS[$i]}"
  t="${FUZZ_TARGETS[$i]}"
  echo "--- building fuzz target: $t (in $d) ---"
  cargo fuzz build --fuzz-dir "$d" --build-std -O --debug-assertions "$t"
  bin=""
  for cand in "$SRC/$d/target/$TRIPLE/release/$t" "$SRC/target/$TRIPLE/release/$t"; do
    [ -x "$cand" ] && bin="$cand" && break
  done
  [ -n "$bin" ] || { echo "ERROR: expected fuzz binary for $t not found" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete"
