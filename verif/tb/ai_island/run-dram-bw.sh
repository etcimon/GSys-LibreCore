#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Directed class-1 LiteDRAM --sim stream BW (records milli-GB/s; not Variane).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_DRAM_BW_OUT:-/tmp/g6lc-ai-dram-bw}"
CORE="$ROOT/corev_apu/ai_island/generated/gateware/litedram_core.v"
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi
if [[ ! -f "$CORE" ]]; then
  echo "SKIP no generated litedram_core.v"
  exit 0
fi
mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
  +define+G6LC_HAVE_LITEDRAM \
  -I"$ROOT/vendor/pulp-platform/axi/include" \
  -I"$ROOT/vendor/pulp-platform/common_cells/include" \
  "$ROOT/vendor/pulp-platform/axi/src/axi_pkg.sv" \
  "$ROOT/vendor/pulp-platform/axi/src/axi_intf.sv" \
  "$ROOT/corev_apu/src/g6lc_ai_litedram_wrap.sv" \
  "$CORE" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_dram_bw.sv" \
  --top-module tb_g6lc_ai_dram_bw \
  -Mdir "$OUT" -o tb_g6lc_ai_dram_bw
"$OUT/tb_g6lc_ai_dram_bw"
echo "PASS tb_g6lc_ai_dram_bw"
