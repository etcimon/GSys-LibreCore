#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Standalone Verilator smoke for g6lc_ai_island_top with EnableDmaFetch=1,
# an AXI stub memory, and the policy codec/steering enabled.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_ISLAND_DMA_OUT:-/tmp/g6lc-ai-island-dma}"
mkdir -p "$OUT"
CCELLS="$ROOT/vendor/pulp-platform/common_cells"
AXI="$ROOT/vendor/pulp-platform/axi"
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
  -I"$AXI/include" \
  -I"$CCELLS/include" \
  -I"$ROOT/core/include" \
  -I"$ROOT/corev_apu/include" \
  -I"$ROOT/corev_apu/ai_island/include" \
  "$CCELLS/src/cf_math_pkg.sv" \
  "$CCELLS/src/lzc.sv" \
  "$CCELLS/src/counter.sv" \
  "$CCELLS/src/delta_counter.sv" \
  "$CCELLS/src/fifo_v3.sv" \
  "$CCELLS/src/spill_register_flushable.sv" \
  "$CCELLS/src/spill_register.sv" \
  "$CCELLS/src/rr_arb_tree.sv" \
  "$AXI/src/axi_pkg.sv" \
  "$AXI/src/axi_intf.sv" \
  "$ROOT/core/include/config_pkg.sv" \
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
  "$ROOT/common/local/util/tc_sram_wrapper.sv" \
  "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
  "$ROOT/corev_apu/ai_island/include/g6lc_ai_desc_pkg.sv" \
  "$ROOT/corev_apu/ai_island/include/g6lc_ai_fp_pkg.sv" \
  "$ROOT/corev_apu/ai_island/include/g6lc_ai_policy_pkg.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_addr_check.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_cap_window.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_desc_engine.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_desc_fetch.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_mem_store.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_tile_sram.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot_float.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot_float_pipe.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_policy_codec.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_policy_steer.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_gemm_seq.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_dram_timing.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_cpl_fifo.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_island_top.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_island_dma.sv" \
  --top-module tb_g6lc_ai_island_dma \
  -Mdir "$OUT" -o tb_g6lc_ai_island_dma \
  --exe "$ROOT/verif/tb/ai_island/ai_island_dma_main.cpp"
"$OUT/tb_g6lc_ai_island_dma"
echo "PASS tb_g6lc_ai_island_dma"
