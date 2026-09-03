#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Testharness exclusive-monitor write path (pulp LRSC = 1 outstanding). Not Variane.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_DRAM_ATOMICS_OUT:-/tmp/g6lc-ai-dram-atomics}"
mkdir -p "$OUT"
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi
CCELLS="$ROOT/vendor/pulp-platform/common_cells"
AXI="$ROOT/vendor/pulp-platform/axi"
AT="$ROOT/vendor/pulp-platform/axi_riscv_atomics/src"
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
  -I"$AXI/include" \
  -I"$CCELLS/include" \
  -I"$ROOT/corev_apu/include" \
  "$CCELLS/src/cf_math_pkg.sv" \
  "$CCELLS/src/lzc.sv" \
  "$CCELLS/src/rr_arb_tree.sv" \
  "$CCELLS/src/stream_arbiter_flushable.sv" \
  "$CCELLS/src/stream_arbiter.sv" \
  "$AXI/src/axi_pkg.sv" \
  "$AXI/src/axi_intf.sv" \
  "$AT/axi_res_tbl.sv" \
  "$AT/axi_riscv_amos_alu.sv" \
  "$AT/axi_riscv_amos.sv" \
  "$AT/axi_riscv_lrsc.sv" \
  "$AT/axi_riscv_atomics.sv" \
  "$AT/axi_riscv_atomics_wrap.sv" \
  "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_atomics_aw.sv" \
  --top-module tb_g6lc_ai_atomics_aw \
  -Mdir "$OUT" -o tb_g6lc_ai_atomics_aw
"$OUT/tb_g6lc_ai_atomics_aw"
echo "PASS tb_g6lc_ai_atomics_aw"

# Multi-outstanding exclusive monitor (S4/CLASS1 path).
OUT2="${AI_DRAM_LRSC_OUT:-/tmp/g6lc-ai-axi-lrsc}"
mkdir -p "$OUT2"
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
  -I"$AXI/include" \
  -I"$CCELLS/include" \
  "$AXI/src/axi_pkg.sv" \
  "$AXI/src/axi_intf.sv" \
  "$ROOT/corev_apu/src/g6lc_axi_lrsc.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_axi_lrsc.sv" \
  --top-module tb_g6lc_axi_lrsc \
  -Mdir "$OUT2" -o tb_g6lc_axi_lrsc
"$OUT2/tb_g6lc_axi_lrsc"
echo "PASS tb_g6lc_axi_lrsc"

# Testharness S4 stack: vendor AMO + g6lc_axi_lrsc.
OUT3="${AI_DRAM_ATOMICS_WRAP_OUT:-/tmp/g6lc-ai-axi-atomics-wrap}"
mkdir -p "$OUT3"
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
  +define+G6LC_TB_ATOMICS_WRAP \
  -I"$AXI/include" \
  -I"$CCELLS/include" \
  "$CCELLS/src/cf_math_pkg.sv" \
  "$CCELLS/src/lzc.sv" \
  "$CCELLS/src/rr_arb_tree.sv" \
  "$CCELLS/src/spill_register_flushable.sv" \
  "$CCELLS/src/spill_register.sv" \
  "$CCELLS/src/stream_arbiter_flushable.sv" \
  "$CCELLS/src/stream_arbiter.sv" \
  "$AXI/src/axi_pkg.sv" \
  "$AXI/src/axi_intf.sv" \
  "$AXI/src/axi_cut.sv" \
  "$AT/axi_res_tbl.sv" \
  "$AT/axi_riscv_amos_alu.sv" \
  "$AT/axi_riscv_amos.sv" \
  "$ROOT/corev_apu/src/g6lc_axi_lrsc.sv" \
  "$ROOT/corev_apu/src/g6lc_axi_atomics_wrap.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_axi_lrsc.sv" \
  --top-module tb_g6lc_axi_lrsc \
  -Mdir "$OUT3" -o tb_g6lc_axi_atomics_wrap
"$OUT3/tb_g6lc_axi_atomics_wrap"
echo "PASS tb_g6lc_axi_atomics_wrap"
