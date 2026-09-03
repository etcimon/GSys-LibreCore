#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S5 capability-window occupancy decode (not LiteDRAM, not Variane).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_CAP_OCC_OUT:-/tmp/g6lc-ai-cap-occupancy}"
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi
mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED \
  -I"$ROOT/corev_apu/include" \
  "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_cap_window.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_cap_occupancy.sv" \
  --top-module tb_g6lc_ai_cap_occupancy \
  -Mdir "$OUT" -o tb_g6lc_ai_cap_occupancy
"$OUT/tb_g6lc_ai_cap_occupancy"
echo "PASS tb_g6lc_ai_cap_occupancy"
