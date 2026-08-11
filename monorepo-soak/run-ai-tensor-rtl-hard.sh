#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Lab-proven HARD path for ai-tensor ↔ island (no rebuild by default).
#
#   bash monorepo-soak/run-ai-tensor-rtl-hard.sh
#   AI_MATRIX_VERI_REBUILD=1 bash monorepo-soak/run-ai-tensor-rtl-hard.sh   # long
#
# Narrow Verilator surface (diag-style; set by build-platform tensor --suite):
#   DV_TARGET / AI_TENSOR_CORE / AI_TENSOR_RTL_TARGET  → g6lc64_ai
#   AI_MATRIX_VER_LIBRARY                             → work-ver-ai
#   AI_MATRIX_VERI_TESTS                              → directed ELF list
#   AI_MATRIX_TIME_OUT                                → cycle budget
#
# Pass criteria (2026-08-10 lab): work-ver-ai reuse; mmio + gemm_s8 smokes SUCCESS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AI_TENSOR_RTL_HARD=1
export AI_MATRIX_VERI_REBUILD="${AI_MATRIX_VERI_REBUILD:-0}"
export AI_MATRIX_VERI_TESTS="${AI_MATRIX_VERI_TESTS:-ai_island_mmio_smoke ai_gemm_s8_smoke}"
export AI_MATRIX_VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai}"
# Propagate package selection into ai-matrix-veri (DV_TARGET)
export DV_TARGET="${DV_TARGET:-${AI_TENSOR_RTL_TARGET:-${AI_TENSOR_CORE:-${CVA6_CORE_CONFIG:-g6lc64_ai}}}}"
export CVA6_CORE_CONFIG="${CVA6_CORE_CONFIG:-$DV_TARGET}"
export AI_TENSOR_CORE="${AI_TENSOR_CORE:-$DV_TARGET}"
exec bash "$ROOT/monorepo-soak/run-ai-tensor-rtl.sh"
