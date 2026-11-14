#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Sweep equivalence of the g6lc_ai_gemm_arplan elems_for_burst forms (r127).
# Negative control: ARPLAN_EQ_DEFINES=-DG6LC_MUT_ARPLAN_EQ must print ..._FAIL.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${AI_ARPLAN_EQ_OUT:-$ROOT/build-platform/workspace/build/ai-arplan-eq}"
mkdir -p "$OUT"
"${VERILATOR:-verilator}" --binary --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  ${ARPLAN_EQ_DEFINES:-} --Mdir "$OUT/model" --top-module tb_g6lc_ai_arplan_eq \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_arplan_eq.sv" > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; exit 1; }
"$OUT/model/Vtb_g6lc_ai_arplan_eq" | grep -E "HYP8_AI_ARPLAN_EQ|FAIL" | head -10
