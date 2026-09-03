#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Standalone stripe-helper smoke (not Variane, not LiteDRAM).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_DRAM_STRIPE_OUT:-/tmp/g6lc-ai-dram-stripe}"
mkdir -p "$OUT"
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD \
  -I"$ROOT/corev_apu/include" \
  "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_dram_stripe.sv" \
  --top-module tb_g6lc_ai_dram_stripe \
  -Mdir "$OUT" -o tb_g6lc_ai_dram_stripe
"$OUT/tb_g6lc_ai_dram_stripe"
echo "PASS tb_g6lc_ai_dram_stripe"
