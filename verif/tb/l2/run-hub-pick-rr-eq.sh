#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Exhaustive equivalence of the g6lc_coherence_hub pick_rr forms (r127), then the
# negative control (-DG6LC_MUT_PICK_RR_EQ must print ..._FAIL).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${HUB_PICK_RR_EQ_OUT:-$ROOT/build-platform/workspace/build/hub-pick-rr-eq}"
for v in plain mut; do
  D=""
  [ "$v" = mut ] && D=-DG6LC_MUT_PICK_RR_EQ
  mkdir -p "$OUT/$v"
  if ! "${VERILATOR:-verilator}" --binary --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC $D --Mdir "$OUT/$v/model" --top-module tb_g6lc_hub_pick_rr_eq "$ROOT/verif/tb/l2/tb_g6lc_hub_pick_rr_eq.sv" > "$OUT/$v/build.log" 2>&1; then
    tail -12 "$OUT/$v/build.log"
    exit 1
  fi
  echo "[$v] $("$OUT/$v/model/Vtb_g6lc_hub_pick_rr_eq" | grep -E "HYP8_HUB_PICK_RR_EQ" | head -1)"
done
