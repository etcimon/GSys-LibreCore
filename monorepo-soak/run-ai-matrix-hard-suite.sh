#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Full (or curated) SoC HARD suite on work-ver-ai — no rebuild by default.
# Post-FIFO CPL lab path; use after Variane_testharness exists.
#
#   bash monorepo-soak/run-ai-matrix-hard-suite.sh           # full DEFAULT_TESTS
#   AI_MATRIX_HARD_SUITE=ci bash monorepo-soak/run-ai-matrix-hard-suite.sh
#   AI_MATRIX_HARD_SUITE=smoke bash monorepo-soak/run-ai-matrix-hard-suite.sh
#   AI_MATRIX_HARD_SUITE=peak bash monorepo-soak/run-ai-matrix-hard-suite.sh
#
# Suites:
#   full  — ai-matrix-veri DEFAULT_TESTS (incl. 256x256 GEMM)
#   ci    — host/FIFO/IRQ/desc + gemm up to 64x64 (no 128/256)
#   smoke — mmio + multi-claim + gemm_s8 (fast lab pair + FIFO)
#   peak  — large GEMM only: 128x128 + 256x256 (long wall time)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AI_TENSOR_RTL_HARD=1
export AI_MATRIX_VERI_REBUILD="${AI_MATRIX_VERI_REBUILD:-0}"
export AI_MATRIX_VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai}"

SUITE="${AI_MATRIX_HARD_SUITE:-full}"
case "$SUITE" in
  full)
    unset AI_MATRIX_VERI_TESTS || true
    ;;
  ci)
    export AI_MATRIX_VERI_TESTS="ai_csr_aistatus_xs ai_setcfg_readback ai_illegal_when_off ai_dot4_s8_smoke ai_mma_s8_golden ai_requant_rhe_golden ai_pmu_group4_smoke ai_queue_doorbell ai_aiperm_umode ai_island_mmio_smoke ai_cpl_fifo_multi_claim ai_enq_sideband_smoke ai_dual_enq_poll ai_irq_plic_smoke ai_desc_fetch_smoke ai_enq_fetch_smoke ai_ptr_done_smoke ai_gemm_s8_smoke ai_gemm_s8_lda_smoke ai_gemm_dim_err_smoke ai_gemm_s8_4x4_smoke ai_gemm_s8_8x8_smoke ai_gemm_s8_16x16_smoke ai_gemm_s8_32x32_smoke ai_gemm_s8_64x64_smoke ai_bw_pmu_smoke ai_cap_bringup_smoke"
    ;;
  smoke)
    export AI_MATRIX_VERI_TESTS="ai_island_mmio_smoke ai_cpl_fifo_multi_claim ai_gemm_s8_smoke"
    ;;
  peak)
    export AI_MATRIX_VERI_TESTS="ai_gemm_s8_128x128_smoke ai_gemm_s8_256x256_smoke"
    export AI_MATRIX_TIME_OUT="${AI_MATRIX_TIME_OUT:-16000000}"
    ;;
  *)
    echo "unknown AI_MATRIX_HARD_SUITE=${SUITE} (full|ci|smoke|peak)" >&2
    exit 2
    ;;
esac

echo "[ai-hard-suite] suite=${SUITE} rebuild=${AI_MATRIX_VERI_REBUILD} library=${AI_MATRIX_VER_LIBRARY}"
if [[ -n "${AI_MATRIX_VERI_TESTS:-}" ]]; then
  echo "[ai-hard-suite] tests=${AI_MATRIX_VERI_TESTS}"
else
  echo "[ai-hard-suite] tests=DEFAULT_TESTS (full)"
fi
exec bash "${ROOT}/verif/regress/ai-matrix-veri.sh"
