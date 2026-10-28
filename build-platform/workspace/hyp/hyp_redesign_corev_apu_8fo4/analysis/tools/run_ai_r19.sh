#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
# Focused r19 gates; run from repo root under WSL.
set -euo pipefail
ROOT="$(pwd)"
export PATH="/usr/bin:/bin:$PATH"
export G6LC_AI_RTL_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island"
export G6LC_AI_INC_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/include"
export G6LC_AI_SRC_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/src"
export AI_ISLAND_DRAM_CHANNELS=1
export AI_GEMM_DPF_LIST="${AI_GEMM_DPF_LIST:-0 2}"
export MAX_K="${MAX_K:-64}"
export R19_MODE="${1:-gemm}"
export AI_GEMM_BACKEND_OUT="$ROOT/build-platform/workspace/build/ai-gemm/r19-$R19_MODE"
export AI_CLUSTER_DISPATCH_OUT="$ROOT/build-platform/workspace/build/ai-gemm/r19-cluster"
export AI_GEMM_WIDE_OUT="$ROOT/build-platform/workspace/build/ai-gemm/r19-wide"
export AI_GEMM_STRIPE_OUT="$ROOT/build-platform/workspace/build/ai-gemm/r19-stripe"
verilator() {
  local args=()
  for arg in "$@"; do
    if [[ "$R19_MODE" == *lint && "$arg" == --binary ]]; then args+=(--lint-only)
    else args+=("$arg"); fi
  done
  /usr/bin/verilator "${args[@]}" --assert -j 2 -DG6LC_AI_HYP_R19
  local result=$?
  if [[ "$R19_MODE" == *lint ]]; then exit "$result"; fi
  return "$result"
}
export -f verilator
case "$R19_MODE" in
  cluster*) bash verif/tb/ai_island/run-cluster-dispatch.sh ;;
  wide*) bash verif/tb/ai_island/run-gemm-wide.sh ;;
  stripe*) unset AI_ISLAND_DRAM_CHANNELS; bash verif/tb/ai_island/run-gemm-stripe.sh ;;
  *)
    if [[ "$R19_MODE" == reuse* ]]; then
      export REUSE_EN=1
      export MAX_N="${MAX_N:-64}"
    fi
    bash verif/tb/ai_island/run-gemm-backend.sh
    if [[ "$R19_MODE" != *lint ]]; then
      for dpf in $AI_GEMM_DPF_LIST; do
        "$AI_GEMM_BACKEND_OUT-n1-dpf$dpf/tb_g6lc_ai_gemm_backend" +review_accumulate +review_fp32_add
      done
      "$AI_GEMM_BACKEND_OUT-n1-dpf${AI_GEMM_DPF_LIST%% *}/tb_g6lc_ai_gemm_backend" +review_protocol
      if [[ "$R19_MODE" == reuse* ]]; then
        "$AI_GEMM_BACKEND_OUT-n1-dpf${AI_GEMM_DPF_LIST%% *}/tb_g6lc_ai_gemm_backend" +review_slots
      fi
    fi
    ;;
esac
