#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Lab RTL hard/soft smoke for ai-tensor cosim bridge (AI_TENSOR_RTL_CMD).
# Does not rebuild TB by default. Package crates never path-dep this script.
#
# Usage:
#   bash monorepo-soak/run-ai-tensor-rtl.sh          # soft probe (default)
#   AI_TENSOR_RTL_HARD=1 bash monorepo-soak/run-ai-tensor-rtl.sh
#   AI_TENSOR_RTL_HARD=1 AI_MATRIX_VERI_TESTS=ai_gemm_s8_smoke \
#     bash monorepo-soak/run-ai-tensor-rtl.sh
#
# Soft (default): exit 0 after printing probe lines (work-ver-ai, scripts).
# Hard: run verif/regress/ai-matrix-veri.sh with a small default test list.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

log() { echo "[ai-tensor-rtl] $*"; }

HARD="${AI_TENSOR_RTL_HARD:-0}"
VERI="${ROOT}/verif/regress/ai-matrix-veri.sh"
ISLAND="${ROOT}/corev_apu/ai_island/README.md"
WORK="${AI_MATRIX_VER_LIBRARY:-work-ver-ai}"
WORK_DIR="${ROOT}/${WORK}"

log "root=${ROOT}"
log "island_readme=$([ -f "$ISLAND" ] && echo ok || echo missing)"
log "ai_matrix_veri=$([ -f "$VERI" ] && echo ok || echo missing)"
log "ver_library=${WORK} present=$([ -d "$WORK_DIR" ] && echo yes || echo no)"

if [[ ! -f "$VERI" ]]; then
  log "soft-skip: no ai-matrix-veri.sh"
  echo "rtl_smoke=skip reason=no_ai_matrix_veri"
  exit 0
fi

if [[ "$HARD" != "1" && "$HARD" != "true" && "$HARD" != "yes" ]]; then
  log "soft probe only (set AI_TENSOR_RTL_HARD=1 for live TB)"
  # Prefer a tiny directed list when hard is later enabled
  echo "rtl_smoke=skip reason=soft_probe veri_script=ok work_ver=$([ -d "$WORK_DIR" ] && echo yes || echo no)"
  exit 0
fi

if [[ ! -d "$WORK_DIR" && "${AI_MATRIX_VERI_REBUILD:-0}" != "1" ]]; then
  log "ERROR: ${WORK} missing — rebuild with AI_MATRIX_VERI_REBUILD=1 (long)"
  echo "rtl_smoke=fail reason=no_work_ver"
  exit 1
fi

# Minimal island GEMM goldens by default (override with AI_MATRIX_VERI_TESTS)
export AI_MATRIX_VERI_TESTS="${AI_MATRIX_VERI_TESTS:-ai_island_mmio_smoke ai_gemm_s8_smoke ai_ptr_done_smoke}"
export AI_MATRIX_VER_LIBRARY="${WORK}"
log "HARD run: AI_MATRIX_VERI_TESTS=${AI_MATRIX_VERI_TESTS}"
bash "$VERI"
echo "rtl_smoke=ok tests=${AI_MATRIX_VERI_TESTS}"
