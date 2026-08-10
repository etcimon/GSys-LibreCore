#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Optional live Variane run of Xg6lcai directed ELFs on g6lc64_ai.
# Rebuilds work-ver-ai if missing or AI_MATRIX_VERI_REBUILD=1.
#
# Usage:
#   bash verif/regress/ai-matrix-veri.sh
#   AI_MATRIX_VERI_REBUILD=1 bash verif/regress/ai-matrix-veri.sh
#   AI_MATRIX_VERI_TESTS="ai_dot4_s8_smoke" bash verif/regress/ai-matrix-veri.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=common-riscv-tools.sh
if [[ -f "$(dirname "$0")/common-riscv-tools.sh" ]]; then
  # shellcheck disable=SC1091
  source "$(dirname "$0")/common-riscv-tools.sh"
fi

export CVA6_REPO_DIR="${CVA6_REPO_DIR:-$ROOT}"
export DV_TARGET="${DV_TARGET:-g6lc64_ai}"
export RISCV="${RISCV:-${HOME}/tools/riscv}"
export VERILATOR_INSTALL_DIR="${VERILATOR_INSTALL_DIR:-${HOME}/tools/oss-cad-suite}"
export CXX="${CXX:-g++}"
export CC="${CC:-gcc}"
[[ -d "${HOME}/tools/oss-cad-suite/bin" ]] && export PATH="${HOME}/tools/oss-cad-suite/bin:${PATH}"
[[ -d "${HOME}/tools/riscv/bin" ]] && export PATH="${HOME}/tools/riscv/bin:${PATH}"
[[ -d "${HOME}/tools/bin" ]] && export PATH="${HOME}/tools/bin:${PATH}"
if [[ -f "${HOME}/tools/oss-cad-suite/environment" ]]; then
  # shellcheck disable=SC1091
  source "${HOME}/tools/oss-cad-suite/environment"
fi
if [[ -z "${SPIKE_INSTALL_DIR:-}" ]]; then
  if [[ -d "$ROOT/build-platform/workspace/tooling/spike" ]]; then
    export SPIKE_INSTALL_DIR="$ROOT/build-platform/workspace/tooling/spike"
  elif [[ -d "${HOME}/tools/spike" ]]; then
    export SPIKE_INSTALL_DIR="${HOME}/tools/spike"
  fi
fi
if [[ -n "${SPIKE_INSTALL_DIR:-}" ]]; then
  export PATH="${SPIKE_INSTALL_DIR}/bin:${PATH}"
  export LD_LIBRARY_PATH="${SPIKE_INSTALL_DIR}/lib:${LD_LIBRARY_PATH:-}"
fi

REBUILD="${AI_MATRIX_VERI_REBUILD:-0}"
VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai}"
DEFAULT_TESTS="ai_csr_aistatus_xs ai_setcfg_readback ai_illegal_when_off ai_dot4_s8_smoke ai_mma_s8_golden ai_requant_rhe_golden ai_pmu_group4_smoke ai_queue_doorbell ai_aiperm_umode ai_island_mmio_smoke ai_enq_sideband_smoke ai_dual_enq_poll ai_irq_plic_smoke ai_desc_fetch_smoke ai_enq_fetch_smoke ai_ptr_done_smoke ai_gemm_s8_smoke ai_gemm_s8_lda_smoke ai_gemm_dim_err_smoke ai_gemm_s8_4x4_smoke ai_gemm_s8_8x8_smoke ai_gemm_s8_16x16_smoke ai_gemm_s8_32x32_smoke ai_gemm_s8_64x64_smoke ai_gemm_s8_128x128_smoke ai_gemm_s8_256x256_smoke ai_cap_bringup_smoke"
# shellcheck disable=SC2206
tests=( ${AI_MATRIX_VERI_TESTS:-$DEFAULT_TESTS} )
# 256x256 GEMM ~0.5-0.7M cycles (PeLanes=64 multi-bank C); headroom for suite.
TIME_OUT="${AI_MATRIX_TIME_OUT:-8000000}"

# Prefer the monorepo-proven Verilator 5.008 (Debian 5.020 hit internal faults
# on this design). Override with VERILATOR_BIN / VERILATOR_ROOT if needed.
if [[ -z "${VERILATOR_ROOT:-}" && -d /root/tools/verilator-v5.008/share/verilator ]]; then
  export PATH="/root/tools/verilator-v5.008/bin:${PATH}"
  export VERILATOR_ROOT=/root/tools/verilator-v5.008/share/verilator
fi

log() { echo "[ai-matrix-veri] $*"; }
log "target=${DV_TARGET} rebuild=${REBUILD} ver-library=${VER_LIBRARY}"
log "verilator: $(command -v verilator) ($(verilator --version 2>/dev/null | head -1))"

command -v verilator >/dev/null || { log "need verilator"; exit 1; }
command -v g++ >/dev/null || { log "need g++"; exit 1; }

# Prefer xpack / none-elf when available (same as mc-mini-veri)
if [[ -x "${HOME}/tools/riscv/bin/riscv-none-elf-gcc" ]]; then
  export PATH="${HOME}/tools/riscv/bin:${PATH}"
  export CROSS_COMPILE=riscv-none-elf-
fi
RISCV_CC="${RISCV_CC:-${CROSS_COMPILE:-riscv-none-elf-}gcc}"
if ! command -v "$RISCV_CC" >/dev/null 2>&1; then
  for p in riscv-none-elf-gcc riscv64-unknown-elf-gcc; do
    if command -v "$p" >/dev/null 2>&1; then RISCV_CC="$p"; break; fi
  done
fi
command -v "$RISCV_CC" >/dev/null || { log "need riscv gcc"; exit 1; }
CROSS_NM="${CROSS_COMPILE:-riscv-none-elf-}nm"
command -v "$CROSS_NM" >/dev/null 2>&1 || CROSS_NM="${RISCV_CC%gcc}nm"

if [[ "$REBUILD" == "1" || ! -x "$ROOT/$VER_LIBRARY/Variane_testharness" ]]; then
  log "verilate target=$DV_TARGET library=$VER_LIBRARY ..."
  rm -rf "$ROOT/$VER_LIBRARY"
  make -C "$ROOT" verilate \
    verilator="verilator --no-timing" \
    target="$DV_TARGET" ver-library="$VER_LIBRARY" \
    XLEN=64 \
    CVA6_REPO_DIR="$CVA6_REPO_DIR" \
    SPIKE_INSTALL_DIR="${SPIKE_INSTALL_DIR:-}" \
    RISCV="$RISCV" \
    VERILATOR_INSTALL_DIR="$VERILATOR_INSTALL_DIR" \
    CXX="$CXX" CC="$CC"
else
  log "reuse $VER_LIBRARY/Variane_testharness"
fi
test -x "$ROOT/$VER_LIBRARY/Variane_testharness" || {
  log "missing harness (set AI_MATRIX_VERI_REBUILD=1)"; exit 1
}

COMMON="$ROOT/verif/tests/custom/common"
LD="$COMMON/link_verilator.ld"
OUT="$ROOT/$VER_LIBRARY/ai_elfs"
mkdir -p "$OUT"
HARNESS="$ROOT/$VER_LIBRARY/Variane_testharness"
PASS=0
FAIL=0

for t in "${tests[@]}"; do
  src="verif/tests/custom/ai/${t}.S"
  elf="$OUT/${t}.elf"
  log "=== $t ==="
  if [[ ! -f "$src" ]]; then
    log "FAIL $t (missing $src)"; FAIL=$((FAIL+1)); continue
  fi
  # g6lc64_ai has F/D/C — allow imafdc; fall back if needed
  if ! "$RISCV_CC" -march=rv64imafdc_zicsr -mabi=lp64d -nostdlib -nostartfiles \
      -T "$LD" -I"$COMMON" -o "$elf" "$src" 2>/dev/null; then
    "$RISCV_CC" -march=rv64imafdc -mabi=lp64d -nostdlib -nostartfiles \
      -T "$LD" -I"$COMMON" -o "$elf" "$src"
  fi
  th=$("$CROSS_NM" "$elf" | awk '$3=="tohost"{print $1; exit}')
  log_file="/tmp/ai-matrix-veri_${t}.log"
  set +e
  "$HARNESS" \
    +time_out="$TIME_OUT" \
    +debug_disable \
    ${th:+ +tohost_addr=0x$th} \
    "$elf" >"$log_file" 2>&1
  set -e
  tail -8 "$log_file"
  # Mini AI tests: tohost=1 pass, tohost=2 fail (bit0 still 1 → SUCCESS tracer)
  if grep -q '\*\*\* SUCCESS \*\*\*' "$log_file"; then
    if grep -qE 'tohost = 2\b|tohost = 0x0*2\b' "$log_file"; then
      log "FAIL $t (tohost fail code 2)"
      FAIL=$((FAIL+1))
    else
      log "PASS $t"
      PASS=$((PASS+1))
    fi
  else
    log "FAIL $t"
    FAIL=$((FAIL+1))
    grep -E "ILLEGAL|exception|FAILED|DIDNOTCONVERGE|tohost" "$log_file" | head -12 || true
  fi
done

log "SUMMARY pass=${PASS} fail=${FAIL} total=${#tests[@]}"
[[ "$FAIL" -eq 0 ]]
