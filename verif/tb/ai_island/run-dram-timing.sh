#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Standalone I3 page-timing smoke (not Variane, not LiteDRAM).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_DRAM_TIMING_OUT:-/tmp/g6lc-ai-dram-timing}"
mkdir -p "$OUT"
if [[ -n "${CVA6_FROM_TIMING:-}${FROM_TIMING:-}" ]]; then
  echo "[dram-timing] from-timing=${CVA6_FROM_TIMING:-$FROM_TIMING} (FO4; not STA)"
fi
if [[ -n "${AI_ISLAND_GHZ:-}" ]]; then
  echo "[dram-timing] ai-ghz=${AI_ISLAND_GHZ}"
fi
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD \
  -I"$ROOT/corev_apu/include" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_dram_timing.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_dram_timing.sv" \
  --top-module tb_g6lc_ai_dram_timing \
  -Mdir "$OUT" -o tb_g6lc_ai_dram_timing
"$OUT/tb_g6lc_ai_dram_timing"
echo "PASS tb_g6lc_ai_dram_timing"
