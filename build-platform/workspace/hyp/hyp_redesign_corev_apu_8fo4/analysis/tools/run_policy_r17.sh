#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
set -euo pipefail
ROOT="$(pwd)"
RTL="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island"
OUT="$ROOT/build-platform/workspace/build/ai-gemm/r17-policy"
mkdir -p "$OUT"
if [[ "${1:-sim}" == island ]]; then
  export PATH="/usr/bin:/bin:$PATH"
  export G6LC_AI_RTL_DIR="$RTL"
  export G6LC_AI_INC_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/include"
  export G6LC_AI_SRC_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/src"
  export G6LC_AI_CVXIF_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/cvxif_g6lc_ai"
  export AI_ISLAND_DMA_OUT="$ROOT/build-platform/workspace/build/ai-gemm/r17-island"
  exec bash verif/tb/ai_island/run-ai-island-dma.sh
fi
MODE=(--binary --timing -j 2)
if [[ "${1:-sim}" == lint ]]; then MODE=(--lint-only --timing); fi
/usr/bin/verilator "${MODE[@]}" --assert -Wall -Wno-fatal -Wno-TIMESCALEMOD \
  -DG6LC_HYP8_POLICY_PIPELINE_TEST \
  -Werror-WIDTH -Werror-LATCH -Werror-MULTIDRIVEN -Werror-UNOPTFLAT \
  -I"$ROOT/core/include" -I"$RTL/include" \
  "$ROOT/core/include/config_pkg.sv" "$ROOT/core/include/g6lc64_ooo_config_pkg.sv" \
  "$RTL/include/g6lc_ai_policy_pkg.sv" \
  "$RTL/g6lc_ai_mul_seq.sv" "$RTL/g6lc_ai_policy_codec.sv" "$RTL/g6lc_ai_policy_subcode.sv" \
  "$RTL/g6lc_ai_policy_topology.sv" "$RTL/g6lc_ai_policy_publish.sv" \
  "$RTL/g6lc_ai_policy_steer.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_policy_steer.sv" \
  --top-module tb_g6lc_ai_policy_pipeline --Mdir "$OUT" -o policy_pipeline
if [[ "${1:-sim}" != lint ]]; then "$OUT/policy_pipeline"; fi
