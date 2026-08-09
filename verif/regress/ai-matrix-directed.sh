#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Xg6lcai directed-test gate (optional; not default verify).
# Stages:
#   1. contract files present (RTL + tests + package)
#   2. package envelope (CvxifEn, COPRO_G6LC_AI, MatrixEn)
#   3. mini ELF compile of directed .S (soft-skip without toolchain)
#   4. optional LIVE_RTL smoke if AI_MATRIX_LIVE_RTL=1 and harness exists
#
# Env:
#   AI_MATRIX_REQUIRE_COMPILE=1  hard-fail without riscv gcc
#   AI_MATRIX_LIVE_RTL=1         attempt Variane run (lab)
#   AI_MATRIX_OUT=<dir>
#
# Priors: architecture/ai-matrix/ · AGENTS-todo AI-1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

REQUIRE_COMPILE="${AI_MATRIX_REQUIRE_COMPILE:-0}"
LIVE_RTL="${AI_MATRIX_LIVE_RTL:-0}"
OUT="${AI_MATRIX_OUT:-/tmp/cva6-ai-matrix-directed}"
mkdir -p "$OUT"

PASS=0; FAIL=0; SKIP=0
log() { echo "[ai-matrix-directed] $*"; }
ok()  { PASS=$((PASS+1)); log "PASS $*"; }
bad() { FAIL=$((FAIL+1)); log "FAIL $*"; }
skip(){ SKIP=$((SKIP+1)); log "SKIP $*"; }

log "OPTIONAL — Xg6lcai directed gate"
log "  package: core/include/g6lc64_ai_config_pkg.sv"

need=(
  core/include/g6lc64_ai_config_pkg.sv
  core/cvxif_g6lc_ai/include/g6lc_ai_instr_pkg.sv
  core/cvxif_g6lc_ai/g6lc_ai_coprocessor.sv
  core/cvxif_g6lc_ai/g6lc_ai_exec.sv
  verif/tests/custom/ai/ai_csr_aistatus_xs.S
  verif/tests/custom/ai/ai_setcfg_readback.S
  verif/tests/custom/ai/ai_illegal_when_off.S
  verif/tests/custom/ai/ai_dot4_s8_smoke.S
  verif/tests/custom/ai/ai_mma_s8_golden.S
  verif/tests/custom/ai/ai_requant_rhe_golden.S
  verif/tests/custom/ai/ai_pmu_group4_smoke.S
  core/cvxif_g6lc_ai/g6lc_ai_acc_bank.sv
  verif/tests/testlist_ai_matrix.yaml
  architecture/ai-matrix/isa-encoding.md
)
for f in "${need[@]}"; do
  if [[ -f "$f" ]]; then ok "present $f"
  else bad "missing $f"; fi
done

pkg=core/include/g6lc64_ai_config_pkg.sv
grep -q "CVA6ConfigCvxifEn = 1" "$pkg" && ok "CvxifEn=1" || bad "CvxifEn"
grep -q "COPRO_G6LC_AI" "$pkg" && ok "COPRO_G6LC_AI" || bad "CoproType"
grep -q "MatrixEn: bit'(1)" "$pkg" && ok "MatrixEn=1" || bad "MatrixEn"
grep -q "CVA6ConfigVExtEn = 0" "$pkg" && ok "VExtEn=0 (seam B)" || bad "VExtEn must be 0"

# CSR address constants must avoid FTRAN
grep -q "CSR_AICFG.*=.*12'h801" core/cvxif_g6lc_ai/include/g6lc_ai_instr_pkg.sv \
  && ok "aicfg @ 0x801 (not FTRAN 0x800)" || bad "aicfg address"

COMMON="$ROOT/verif/tests/custom/common"
LD="$COMMON/link_verilator.ld"
RISCV_CC="${RISCV_CC:-}"
if [[ -z "$RISCV_CC" ]]; then
  for p in riscv-none-elf-gcc riscv64-unknown-elf-gcc; do
    if command -v "$p" >/dev/null 2>&1; then RISCV_CC="$p"; break; fi
  done
fi

if [[ -z "$RISCV_CC" ]]; then
  if [[ "$REQUIRE_COMPILE" = "1" ]]; then
    bad "no RISC-V gcc (AI_MATRIX_REQUIRE_COMPILE=1)"
  else
    skip "no RISC-V gcc — ELF compile skipped"
  fi
else
  for t in ai_csr_aistatus_xs ai_dot4_s8_smoke ai_mma_s8_golden ai_requant_rhe_golden; do
    src="verif/tests/custom/ai/${t}.S"
    elf="$OUT/${t}.elf"
    if "$RISCV_CC" -march=rv64imafdc -mabi=lp64d -static -mcmodel=medany \
        -fvisibility=hidden -nostdlib -nostartfiles \
        -T"$LD" -I"$COMMON" -o "$elf" "$src" 2>"$OUT/${t}.cc.err"; then
      ok "compile $t → $elf"
    else
      bad "compile $t (see $OUT/${t}.cc.err)"
    fi
  done
fi

if [[ "$LIVE_RTL" = "1" ]]; then
  skip "LIVE_RTL path not automated yet — run manually under g6lc64_ai Variane"
else
  skip "LIVE_RTL=0 (set AI_MATRIX_LIVE_RTL=1 for lab sim)"
fi

log "RESULT pass=$PASS fail=$FAIL skip=$SKIP"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
