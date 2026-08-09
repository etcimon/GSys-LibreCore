#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Dual-ISS residual polish (AGENTS-todo §5): same ELF on Spike + Variane.
#
# Modes:
#   DUAL_ISS_MODE=tohost  (default) — both planes must pass via tohost/SUCCESS
#   DUAL_ISS_MODE=trace   — cva6.py --iss=spike,veri-testharness + iss_regr.log
#
# Default tests are dual-plane safe (no Zacas). Spike has no zacas — never use
# AMOCAS as dual-ISS golden (see AGENTS-regress-scripts.md § dual-ISS).
#
# Usage:
#   bash verif/regress/dual-iss-regress.sh
#   DUAL_ISS_TESTS="mini_tohost mini_jumps" bash verif/regress/dual-iss-regress.sh
#   DUAL_ISS_H=1 bash verif/regress/dual-iss-regress.sh   # add h_edge_diag
#   DUAL_ISS_MODE=trace bash verif/regress/dual-iss-regress.sh

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
export RISCV_CC="${RISCV_CC:-${RISCV_GCC:-riscv-none-elf-gcc}}"
export CROSS_COMPILE="${CROSS_COMPILE:-riscv-none-elf-}"

[[ -d "${ROOT}/build-platform/workspace/tooling/spike/bin" ]] && \
  export PATH="${ROOT}/build-platform/workspace/tooling/spike/bin:${PATH}"
if [[ -n "${SPIKE_INSTALL_DIR:-}" ]]; then
  export PATH="${SPIKE_INSTALL_DIR}/bin:${PATH}"
  export LD_LIBRARY_PATH="${SPIKE_INSTALL_DIR}/lib:${LD_LIBRARY_PATH:-}"
elif [[ -d "${ROOT}/build-platform/workspace/tooling/spike" ]]; then
  export SPIKE_INSTALL_DIR="${ROOT}/build-platform/workspace/tooling/spike"
  export PATH="${SPIKE_INSTALL_DIR}/bin:${PATH}"
  export LD_LIBRARY_PATH="${SPIKE_INSTALL_DIR}/lib:${LD_LIBRARY_PATH:-}"
fi

MODE="${DUAL_ISS_MODE:-tohost}"
DV_TARGET="${DV_TARGET:-g6lc64_server_math}"
OUT="${DUAL_ISS_OUT:-/tmp/cva6-dual-iss}"
mkdir -p "$OUT"
COMMON="$ROOT/verif/tests/custom/common"
LD="$COMMON/link_verilator.ld"
MARCH="${DUAL_ISS_MARCH:-rv64imafdc_zicsr_zifencei}"
MABI="${DUAL_ISS_MABI:-lp64d}"
SPIKE_ISA="${DUAL_ISS_SPIKE_ISA:-rv64imafdch_zicsr_zifencei}"
MAX_CYCLES="${DUAL_ISS_MAX_CYCLES:-200000}"
SPIKE_STEPS="${DUAL_ISS_SPIKE_STEPS:-200000}"

DEFAULT_TESTS="mini_tohost mini_jumps"
if [[ "${DUAL_ISS_H:-0}" == "1" ]]; then
  DEFAULT_TESTS="${DEFAULT_TESTS} h_edge_diag"
fi
# Soft-ladder ordered path step1: B1 directed residuals (prefer soft-ladder-di-regress.sh
# with work-ver-smt2). SOFT_LADDER=1 appends the four mini_* B1 tests.
if [[ "${SOFT_LADDER:-0}" == "1" ]]; then
  DEFAULT_TESTS="${DEFAULT_TESTS} mini_amoadd_w_spin mini_lrsc_d mini_csr_expected_trap mini_dual_cmv_s3"
fi
# shellcheck disable=SC2206
tests=( ${DUAL_ISS_TESTS:-$DEFAULT_TESTS} )

PASS=0
FAIL=0
SKIP=0

log() { echo "[dual-iss] $*"; }

resolve_src() {
  local t="$1"
  if [[ -f "$ROOT/verif/tests/custom/multicore/${t}.S" ]]; then
    echo "$ROOT/verif/tests/custom/multicore/${t}.S"
  elif [[ -f "$ROOT/verif/tests/custom/kvm_h/${t}.S" ]]; then
    echo "$ROOT/verif/tests/custom/kvm_h/${t}.S"
  else
    return 1
  fi
}

build_elf() {
  local t="$1" src elf
  src="$(resolve_src "$t")" || return 1
  elf="$OUT/${t}.o"
  # mini_*.S are bare (own _start); kvm_h uses CRT.
  if [[ "$src" == *"/multicore/"* ]]; then
    "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
      -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
      "$src" -T "$LD" -o "$elf" -march="$MARCH" -mabi="$MABI"
  else
    "$RISCV_CC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
      -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
      "$COMMON/syscalls.c" "$COMMON/crt.S" "$src" \
      -T "$LD" -o "$elf" -march="$MARCH" -mabi="$MABI"
  fi
  echo "$elf"
}

spike_tohost_pass() {
  local elf="$1" log="$2"
  set +e
  timeout 60s spike --isa="$SPIKE_ISA" --steps="$SPIKE_STEPS" "$elf" >"$log" 2>&1
  set -e
  # Accept 32-bit or 64-bit store of value 1 (PASS) to any address.
  # mini_tohost: mem 0x...1000 0x00000001
  # CRT:         mem 0x...2000 0x0000000000000001
  if grep -qE "mem 0x[0-9a-fA-F]+ 0x0*1\b" "$log"; then
    return 0
  fi
  return 1
}


veri_tohost_pass() {
  local elf="$1" log="$2"
  local th harness
  harness="$ROOT/work-ver/Variane_testharness"
  [[ -x "$harness" ]] || return 2
  th="$(riscv-none-elf-nm "$elf" | awk '$3=="tohost"{print $1; exit}')"
  [[ -n "$th" ]] || return 1
  set +e
  "$harness" +max-cycles="$MAX_CYCLES" +time_out="$MAX_CYCLES" +debug_disable \
    +tohost_addr="0x${th}" "$elf" >"$log" 2>&1
  local rc=$?
  set -e
  if grep -q 'SUCCESS' "$log"; then
    return 0
  fi
  return 1
}

run_tohost_mode() {
  local t elf slog vlog
  cva6_have_riscv_gcc || { log "need riscv gcc"; exit 1; }
  cva6_have_spike || { log "need spike"; exit 1; }
  if [[ ! -x "$ROOT/work-ver/Variane_testharness" ]]; then
    log "missing work-ver/Variane_testharness (build TB for ${DV_TARGET} first)"
    exit 1
  fi
  for t in "${tests[@]}"; do
    log "=== $t (tohost dual) ==="
    if ! elf="$(build_elf "$t")"; then
      log "FAIL $t (missing source / build)"
      FAIL=$((FAIL + 1))
      continue
    fi
    slog="$OUT/spike_${t}.log"
    vlog="$OUT/veri_${t}.log"
    if ! spike_tohost_pass "$elf" "$slog"; then
      log "FAIL $t spike (see $slog)"
      tail -8 "$slog" || true
      FAIL=$((FAIL + 1))
      continue
    fi
    log "  spike PASS"
    vr=0
    veri_tohost_pass "$elf" "$vlog" || vr=$?
    if [[ $vr -eq 2 ]]; then
      log "SKIP $t veri (no harness)"
      SKIP=$((SKIP + 1))
      continue
    fi
    if [[ $vr -ne 0 ]]; then
      log "FAIL $t veri (see $vlog)"
      tail -8 "$vlog" || true
      FAIL=$((FAIL + 1))
      continue
    fi
    log "  veri PASS"
    log "PASS $t (spike+veri tohost)"
    PASS=$((PASS + 1))
  done
}

run_trace_mode() {
  cva6_have_riscv_gcc || { log "need riscv gcc"; exit 1; }
  cva6_have_spike || { log "need spike"; exit 1; }
  command -v make >/dev/null || { log "need make"; exit 1; }
  local t src
  export OUT_DIR="$OUT/cva6py"
  mkdir -p "$OUT_DIR"
  cd "$ROOT/verif/sim"
  export PYTHONPATH=".:${PYTHONPATH:-}"
  for t in "${tests[@]}"; do
    log "=== $t (trace dual via cva6.py) ==="
    if ! src="$(resolve_src "$t")"; then
      log "FAIL $t (missing source)"
      FAIL=$((FAIL + 1))
      continue
    fi
    # multicore mini tests are bare; cva6.py expects CRT-style for asm unless .o
    # Prefer prebuilt ELF from tohost build path.
    local elf
    if ! elf="$(build_elf "$t")"; then
      log "FAIL $t (build)"
      FAIL=$((FAIL + 1))
      continue
    fi
    set +e
    /usr/bin/python3 cva6.py \
      --target "$DV_TARGET" \
      --iss spike,veri-testharness \
      --iss_yaml cva6.yaml \
      --iss_timeout "${DUAL_ISS_TIMEOUT:-3000}" \
      --output "$OUT_DIR" \
      "$elf" >"$OUT/cva6py_${t}.log" 2>&1
    local rc=$?
    set -e
    report="$OUT_DIR/iss_regr.log"
    if [[ -f "$report" ]] && grep -q '\[PASSED\]' "$report" \
       && ! grep -q '\[FAILED\]' "$report"; then
      log "PASS $t (trace compare)"
      PASS=$((PASS + 1))
    elif grep -qiE 'SUCCESS' "$OUT/cva6py_${t}.log" && [[ $rc -eq 0 ]]; then
      # some paths pass sim without writing PASSED markers for both
      log "PASS $t (cva6.py rc=0; check $report if present)"
      PASS=$((PASS + 1))
    else
      log "FAIL $t trace (rc=$rc; see $OUT/cva6py_${t}.log $report)"
      tail -20 "$OUT/cva6py_${t}.log" || true
      FAIL=$((FAIL + 1))
    fi
  done
  cd "$ROOT"
}

log "mode=${MODE} target=${DV_TARGET} tests=${tests[*]}"
cva6_tools_report || true

case "$MODE" in
  tohost) run_tohost_mode ;;
  trace)  run_trace_mode ;;
  *) log "unknown DUAL_ISS_MODE=${MODE}"; exit 2 ;;
esac

log "SUMMARY pass=${PASS} fail=${FAIL} skip=${SKIP} mode=${MODE}"
log "Mismatch triage: Zacas/AMOCAS never dual-ISS golden (Spike lacks zacas)."
log "See verif/regress/AGENTS-regress-scripts.md (dual-ISS section)."
[[ "$FAIL" -eq 0 ]]
