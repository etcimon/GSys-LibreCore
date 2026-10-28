#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
# Run from the repository root under WSL. Reuse the existing golden benches.
set -euo pipefail
ROOT="$(pwd)"
export PATH="/usr/bin:/bin:$PATH"
export G6LC_AI_RTL_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island"
export G6LC_AI_INC_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/include"
export G6LC_AI_SRC_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/src"
export AI_ISLAND_DRAM_CHANNELS=1
export AI_GEMM_DPF_LIST="${AI_GEMM_DPF_LIST:-0 2}"
export AI_GEMM_BACKEND_OUT="$ROOT/build-platform/workspace/build/ai-gemm/r18-gemm"
export AI_CLUSTER_DISPATCH_OUT="$ROOT/build-platform/workspace/build/ai-gemm/r18-cluster"
export R18_MODE="${1:-gemm}"
verilator() {
  local args=()
  for arg in "$@"; do
    if [[ "$R18_MODE" == *lint && "$arg" == --binary ]]; then args+=(--lint-only)
    else args+=("$arg"); fi
  done
  /usr/bin/verilator "${args[@]}" --assert -j 2
  local result=$?
  if [[ "$R18_MODE" == *lint ]]; then exit "$result"; fi
  return "$result"
}
export -f verilator
if [[ "$R18_MODE" == cluster* ]]; then
  bash verif/tb/ai_island/run-cluster-dispatch.sh
else
  bash verif/tb/ai_island/run-gemm-backend.sh
  if [[ "$R18_MODE" == *lint ]]; then exit 0; fi
  for dpf in $AI_GEMM_DPF_LIST; do
    "$AI_GEMM_BACKEND_OUT-n1-dpf$dpf/tb_g6lc_ai_gemm_backend" +review_accumulate
  done
fi
