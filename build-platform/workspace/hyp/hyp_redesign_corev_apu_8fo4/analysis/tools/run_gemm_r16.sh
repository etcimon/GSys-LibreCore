#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
# Focused hyp GEMM source closure; run under WSL from the repository root.
set -euo pipefail
ROOT="$(pwd)"
export PATH="/usr/bin:/bin:$PATH"
export G6LC_AI_RTL_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/ai_island"
export G6LC_AI_INC_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/include"
export G6LC_AI_SRC_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/src"
export AI_ISLAND_DRAM_CHANNELS="${AI_ISLAND_DRAM_CHANNELS:-1}"
export AI_GEMM_DPF_LIST="${AI_GEMM_DPF_LIST:-0}"
export AI_GEMM_BACKEND_OUT="$ROOT/build-platform/workspace/build/ai-gemm/r16-${1:-sim}"
verilator() {
  local args=()
  for arg in "$@"; do
    if [[ "${R16_MODE:-sim}" == lint && "$arg" == --binary ]]; then
      args+=(--lint-only)
    else
      args+=("$arg")
    fi
  done
  /usr/bin/verilator "${args[@]}"
  local result=$?
  if [[ "${R16_MODE:-sim}" == lint ]]; then exit "$result"; fi
  return "$result"
}
export R16_MODE="${1:-sim}"
export -f verilator
bash verif/tb/ai_island/run-gemm-backend.sh
