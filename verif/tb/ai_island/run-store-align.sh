#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Completion store: aligned 8-byte word, top lane of a 512-bit beat, refuse +4.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi
OUT="${AI_STORE_ALIGN_OUT:-/tmp/g6lc-ai-store-align}"
AXI="$ROOT/vendor/pulp-platform/axi"
mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
  -I"$AXI/include" \
  -I"$ROOT/corev_apu/include" \
  "$AXI/src/axi_pkg.sv" \
  "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_mem_store.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_store_align.sv" \
  --top-module tb_g6lc_ai_store_align \
  -Mdir "$OUT" -o tb_g6lc_ai_store_align
"$OUT/tb_g6lc_ai_store_align"
echo "PASS run-store-align"
