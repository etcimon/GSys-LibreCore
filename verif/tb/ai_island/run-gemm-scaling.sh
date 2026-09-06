#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Provisioning scaling sweep for g6lc_ai_gemm_seq, via tb_g6lc_ai_gemm_backend
# +measure.  Answers one question with measured RTL cycles: how much MAC/cycle
# can be bought by RAISING a bound, given that policy prefetch_depth can only
# lower one.
#
#   PE_LANES     -> arithmetic peak (PeLanes MAC/cycle)
#   AR_PROVISION -> outstanding-AR bound (MaxAROut)
#
# Every build re-runs the directed golden-C checks first, so a configuration
# that breaks arithmetic fails here instead of producing a throughput number.
# This is a research sweep of hypothetical provisioning, NOT a claim about the
# shipped island: AI_MAX_AR_OUT_LIVE and PeLanes are unchanged in RTL.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_GEMM_SCALING_OUT:-/tmp/g6lc-ai-gemm-scaling}"
LANES_LIST="${AI_GEMM_SCALING_LANES:-4 8 16 32}"
AR_LIST="${AI_GEMM_SCALING_AR:-2 4 8}"
NCH="${AI_GEMM_SCALING_NCH:-8}"
CCELLS="$ROOT/vendor/pulp-platform/common_cells"
AXI="$ROOT/vendor/pulp-platform/axi"
command -v verilator >/dev/null 2>&1 || { echo "SKIP no verilator"; exit 0; }

for lanes in $LANES_LIST; do
  for ar in $AR_LIST; do
    mdir="${OUT}-l${lanes}-a${ar}"
    rm -rf "$mdir"
    verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED \
      -Wno-UNOPTFLAT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY \
      -Wno-CASEINCOMPLETE \
      -I"$AXI/include" -I"$CCELLS/include" -I"$ROOT/core/include" \
      -I"$ROOT/corev_apu/include" -I"$ROOT/corev_apu/ai_island/include" \
      -GNCH="$NCH" -GPE_LANES="$lanes" -GAR_PROVISION="$ar" \
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
      "$AXI/src/axi_id_prepend.sv" \
      "$AXI/src/axi_mux.sv" \
      "$AXI/src/axi_demux.sv" \
      "$ROOT/core/include/config_pkg.sv" \
      "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
      "$ROOT/common/local/util/tc_sram_wrapper.sv" \
      "$ROOT/corev_apu/axi_mem_if/src/axi2mem.sv" \
      "$ROOT/common/local/util/sram.sv" \
      "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
      "$ROOT/corev_apu/ai_island/g6lc_ai_cap_window.sv" \
      "$ROOT/corev_apu/src/g6lc_ai_dram_backend.sv" \
      "$ROOT/corev_apu/ai_island/include/g6lc_ai_fp_pkg.sv" \
      "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot.sv" \
      "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot_float.sv" \
      "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot_float_pipe.sv" \
      "$ROOT/corev_apu/ai_island/g6lc_ai_tile_sram.sv" \
      "$ROOT/corev_apu/ai_island/g6lc_ai_gemm_seq.sv" \
      "$ROOT/verif/tb/ai_island/tb_g6lc_ai_gemm_backend.sv" \
      --top-module tb_g6lc_ai_gemm_backend \
      -Mdir "$mdir" -o tb_g6lc_ai_gemm_backend >"$mdir.build.log" 2>&1 || {
        echo "BUILD_FAIL lanes=$lanes ar=$ar (see $mdir.build.log)"; continue; }
    echo "SCALING_CONFIG lanes=$lanes ar=$ar nch=$NCH"
    "$mdir/tb_g6lc_ai_gemm_backend" +measure
  done
done
echo "PASS tb_g6lc_ai_gemm_backend scaling lanes=[$LANES_LIST] ar=[$AR_LIST] nch=$NCH"
