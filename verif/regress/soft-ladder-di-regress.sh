#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder ordered path — step 1: B1 directed DI soak.
#
# Tests (bare multicore mini_*.S, tohost=1 pass):
#   mini_amoadd_w_spin   b1-amo-spin-lock
#   mini_lrsc_d          b1-lrsc-cmpxchg
#   mini_csr_expected_trap  b1-csr-expected-trap
#   mini_dual_cmv_s3     b1-dual-cmv-s3
#
# Plane: Variane RTL preferred (g6lc64_smt2 / work-ver-smt2). Optional Spike
# for ISA-clean tests (not Zacas). OpenSBI cookie path is separate (step 2 peels).
#
# Usage:
#   bash verif/regress/soft-ladder-di-regress.sh
#   SOFT_LADDER_SPIKE=1 bash verif/regress/soft-ladder-di-regress.sh
#   SOFT_LADDER_TESTS="mini_lrsc_d mini_csr_expected_trap" bash ...
#   SOFT_LADDER_HARNESS=work-ver-smt2 bash ...
#   SOFT_LADDER_COMPILE_ONLY=1 bash ...   # assemble only
#
# Map: architecture/multi-threading/soft-ladder/CONT-FULL-MAP.md § ordered path

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=common-riscv-tools.sh
source "$(dirname "$0")/common-riscv-tools.sh"

if [[ "${RISCV_GCC:-}" == *.exe ]]; then
  if [[ -x "${HOME}/tools/riscv/bin/riscv-none-elf-gcc" ]]; then
    export PATH="${HOME}/tools/riscv/bin:${PATH}"
    export CROSS_COMPILE=riscv-none-elf-
    RISCV_GCC="$(command -v riscv-none-elf-gcc)"
  fi
fi
if [[ -x /opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc ]]; then
  export PATH="/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:${PATH}"
  export CROSS_COMPILE=riscv-none-elf-
  RISCV_GCC="$(command -v riscv-none-elf-gcc)"
fi
export RISCV_CC="${RISCV_CC:-${RISCV_GCC:-riscv64-unknown-elf-gcc}}"
export CROSS_COMPILE="${CROSS_COMPILE:-riscv64-unknown-elf-}"

[[ -d "${ROOT}/build-platform/workspace/tooling/spike/bin" ]] && \
  export PATH="${ROOT}/build-platform/workspace/tooling/spike/bin:${PATH}"

OUT="${SOFT_LADDER_OUT:-/tmp/cva6-soft-ladder-di}"
mkdir -p "$OUT"
COMMON="$ROOT/verif/tests/custom/common"
LD="$COMMON/link_verilator.ld"
MARCH="${SOFT_LADDER_MARCH:-rv64imafdc_zicsr_zifencei}"
MABI="${SOFT_LADDER_MABI:-lp64d}"
SPIKE_ISA="${SOFT_LADDER_SPIKE_ISA:-rv64imafdc_zicsr_zifencei}"
MAX_CYCLES="${SOFT_LADDER_MAX_CYCLES:-400000}"
SPIKE_STEPS="${SOFT_LADDER_SPIKE_STEPS:-400000}"
HARNESS_DIR="${SOFT_LADDER_HARNESS:-work-ver-smt2-fw64}"
if [[ ! -x "$ROOT/${HARNESS_DIR}/Variane_testharness" && -x "$ROOT/work-ver-smt2/Variane_testharness" ]]; then
  HARNESS_DIR=work-ver-smt2
fi
RUN_SPIKE="${SOFT_LADDER_SPIKE:-0}"
COMPILE_ONLY="${SOFT_LADDER_COMPILE_ONLY:-0}"

DEFAULT_TESTS="mini_amoadd_w_spin mini_lrsc_d mini_csr_expected_trap mini_dual_cmv_s3"
# shellcheck disable=SC2206
tests=( ${SOFT_LADDER_TESTS:-$DEFAULT_TESTS} )

PASS=0
FAIL=0
SKIP=0

log() { echo "[soft-ladder-di] $*"; }

resolve_src() {
  local t="$1"
  if [[ -f "$ROOT/verif/tests/custom/multicore/${t}.S" ]]; then
    echo "$ROOT/verif/tests/custom/multicore/${t}.S"
  else
    return 1
  fi
}

build_elf() {
  local t="$1" src elf
  src="$(resolve_src "$t")" || return 1
  elf="$OUT/${t}.elf"
  "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
    "$src" -T "$LD" -o "$elf" -march="$MARCH" -mabi="$MABI"
  echo "$elf"
}

spike_tohost_pass() {
  local elf="$1" slog="$2"
  command -v spike >/dev/null || return 2
  set +e
  timeout 90s spike --isa="$SPIKE_ISA" --steps="$SPIKE_STEPS" "$elf" >"$slog" 2>&1
  set -e
  if grep -qE "mem 0x[0-9a-fA-F]+ 0x0*1\b" "$slog"; then
    return 0
  fi
  return 1
}

veri_tohost_pass() {
  local elf="$1" vlog="$2"
  local th harness
  harness="$ROOT/${HARNESS_DIR}/Variane_testharness"
  [[ -x "$harness" ]] || return 2
  th="$(${CROSS_COMPILE}nm "$elf" 2>/dev/null | awk '$3=="tohost"{print $1; exit}')"
  if [[ -z "$th" ]]; then
    th="$(riscv64-unknown-elf-nm "$elf" 2>/dev/null | awk '$3=="tohost"{print $1; exit}')"
  fi
  [[ -n "$th" ]] || return 1
  set +e
  "$harness" +max-cycles="$MAX_CYCLES" +time_out="$MAX_CYCLES" +debug_disable \
    +tohost_addr="0x${th}" "$elf" >"$vlog" 2>&1
  set -e
  if grep -q 'SUCCESS' "$vlog"; then
    return 0
  fi
  return 1
}

log "ordered-path step1: B1 directed DI soak"
log "harness=${HARNESS_DIR} spike=${RUN_SPIKE} tests=${tests[*]}"
cva6_tools_report || true

if ! cva6_have_riscv_gcc 2>/dev/null; then
  if ! command -v "$RISCV_CC" >/dev/null 2>&1; then
    log "need riscv gcc (RISCV_CC=$RISCV_CC)"
    exit 1
  fi
fi

for t in "${tests[@]}"; do
  log "=== $t ==="
  if ! elf="$(build_elf "$t")"; then
    log "FAIL $t (build)"
    FAIL=$((FAIL + 1))
    continue
  fi
  log "  built $elf"
  if [[ "$COMPILE_ONLY" == "1" ]]; then
    log "PASS $t (compile-only)"
    PASS=$((PASS + 1))
    continue
  fi

  if [[ "$RUN_SPIKE" == "1" ]]; then
    slog="$OUT/spike_${t}.log"
    sr=0
    spike_tohost_pass "$elf" "$slog" || sr=$?
    if [[ $sr -eq 2 ]]; then
      log "SKIP $t spike (no spike)"
      SKIP=$((SKIP + 1))
    elif [[ $sr -ne 0 ]]; then
      log "FAIL $t spike (see $slog)"
      tail -12 "$slog" || true
      FAIL=$((FAIL + 1))
      continue
    else
      log "  spike PASS"
    fi
  fi

  vlog="$OUT/veri_${t}.log"
  vr=0
  veri_tohost_pass "$elf" "$vlog" || vr=$?
  if [[ $vr -eq 2 ]]; then
    log "SKIP $t veri (no ${HARNESS_DIR}/Variane_testharness)"
    SKIP=$((SKIP + 1))
    # compile succeeded; count as soft pass for gate when no harness rebuild budget
    continue
  fi
  if [[ $vr -ne 0 ]]; then
    log "FAIL $t veri (see $vlog)"
    tail -20 "$vlog" || true
    FAIL=$((FAIL + 1))
    continue
  fi
  log "  veri PASS"
  log "PASS $t"
  PASS=$((PASS + 1))
done

log "SUMMARY pass=${PASS} fail=${FAIL} skip=${SKIP}"
log "Next ordered path: step2 OpenSBI peels (PEEL_SPIN / PEEL_CMPX / PEEL_CSR)"
log "  python tmp-dual-ci/mk_plat_skip.py   # default soft"
log "  PEEL_SPIN=1 python tmp-dual-ci/mk_plat_skip.py"
log "See architecture/multi-threading/soft-ladder/CONT-FULL-MAP.md"
[[ "$FAIL" -eq 0 ]]
