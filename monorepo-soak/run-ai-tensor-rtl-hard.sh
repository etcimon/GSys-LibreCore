#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Lab-proven HARD path for ai-tensor ↔ island (no rebuild by default).
#
#   bash monorepo-soak/run-ai-tensor-rtl-hard.sh
#   AI_MATRIX_VERI_REBUILD=1 bash monorepo-soak/run-ai-tensor-rtl-hard.sh   # long
#
# Pass criteria (2026-08-10 lab): work-ver-ai reuse; mmio + gemm_s8 smokes SUCCESS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AI_TENSOR_RTL_HARD=1
export AI_MATRIX_VERI_REBUILD="${AI_MATRIX_VERI_REBUILD:-0}"
export AI_MATRIX_VERI_TESTS="${AI_MATRIX_VERI_TESTS:-ai_island_mmio_smoke ai_gemm_s8_smoke}"
export AI_MATRIX_VER_LIBRARY="${AI_MATRIX_VER_LIBRARY:-work-ver-ai}"
exec bash "$ROOT/monorepo-soak/run-ai-tensor-rtl.sh"
