#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Descriptor fetch refuses a 64-byte stripe cross. N=1 is not this run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi
OUT="${AI_DESC_STRIPE_OUT:-/tmp/g6lc-ai-desc-stripe}"
AXI="$ROOT/vendor/pulp-platform/axi"
mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
  -I"$AXI/include" \
  -I"$ROOT/corev_apu/include" \
  -I"$ROOT/corev_apu/ai_island/include" \
  "$AXI/src/axi_pkg.sv" \
  "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
  "$ROOT/corev_apu/ai_island/include/g6lc_ai_desc_pkg.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_desc_fetch.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_desc_stripe.sv" \
  --top-module tb_g6lc_ai_desc_stripe \
  -Mdir "$OUT" -o tb_g6lc_ai_desc_stripe
"$OUT/tb_g6lc_ai_desc_stripe"
echo "PASS run-desc-stripe"
