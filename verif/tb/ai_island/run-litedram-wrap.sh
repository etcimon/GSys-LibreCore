#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Standalone class-1 LiteDRAM wrap smoke (not Variane).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_LITEDRAM_WRAP_OUT:-/tmp/g6lc-ai-litedram-wrap}"
CORE="$ROOT/corev_apu/ai_island/generated/gateware/litedram_core.v"
mkdir -p "$OUT"
if [[ -n "${CVA6_FROM_TIMING:-}${FROM_TIMING:-}" ]]; then
  echo "[litedram-wrap] from-timing=${CVA6_FROM_TIMING:-$FROM_TIMING} (FO4; not STA)"
fi
echo "[litedram-wrap] class=${AI_ISLAND_DRAM_CLASS:-1} channels=${AI_ISLAND_DRAM_CHANNELS:-1} flavour=${AI_MATRIX_FLAVOUR:-}"
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi
if [[ ! -f "$CORE" ]]; then
  echo "SKIP no generated litedram_core.v"
  exit 0
fi
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
  +define+G6LC_HAVE_LITEDRAM \
  -I"$ROOT/vendor/pulp-platform/axi/include" \
  -I"$ROOT/vendor/pulp-platform/common_cells/include" \
  "$ROOT/vendor/pulp-platform/axi/src/axi_pkg.sv" \
  "$ROOT/vendor/pulp-platform/axi/src/axi_intf.sv" \
  "$ROOT/corev_apu/src/g6lc_ai_litedram_wrap.sv" \
  "$CORE" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_litedram_wrap.sv" \
  --top-module tb_g6lc_ai_litedram_wrap \
  -Mdir "$OUT" -o tb_g6lc_ai_litedram_wrap
"$OUT/tb_g6lc_ai_litedram_wrap"
echo "PASS tb_g6lc_ai_litedram_wrap"
