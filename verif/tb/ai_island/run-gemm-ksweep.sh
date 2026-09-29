#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Tests one prediction: the lanes a dot can use is the operand row in bytes
# (k_bytes), not a function of element width alone.
#
# g6lc_ai_gemm_seq ends a reduction when mac_step >= k, with mac_step = 2*PeLanes
# for INT4 and PeLanes/bytes otherwise.  The committed +measure basis only ever
# ran k=16, where "k_bytes" and "twice the element width" coincide.  Under the
# rule, INT4's best lane count should move 8 -> 16 -> 32 as k goes 16 -> 32 -> 64,
# and INT8's 16 -> 32 -> 64.  If the optimum does not move, the decision is not
# k-dependent and a runtime sub-code has no varying choice to make.
#
# Integer formats only (golden C is exactly k) and MaxDim=64 so k can exceed 16.
# Research sweep of hypothetical provisioning: no shipped RTL parameter changes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_GEMM_KSWEEP_OUT:-/tmp/g6lc-ai-gemm-ksweep}"
LANES_LIST="${AI_GEMM_KSWEEP_LANES:-8 16 32}"
MAXDIM="${AI_GEMM_KSWEEP_MAXDIM:-64}"
NCH="${AI_GEMM_KSWEEP_NCH:-1}"
CCELLS="$ROOT/vendor/pulp-platform/common_cells"
AXI="$ROOT/vendor/pulp-platform/axi"
command -v verilator >/dev/null 2>&1 || { echo "SKIP no verilator"; exit 0; }

for lanes in $LANES_LIST; do
  mdir="${OUT}-l${lanes}"
  rm -rf "$mdir"
  verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-UNOPTFLAT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY \
    -Wno-CASEINCOMPLETE \
    -I"$AXI/include" -I"$CCELLS/include" -I"$ROOT/core/include" \
    -I"$ROOT/corev_apu/include" -I"$ROOT/corev_apu/ai_island/include" \
    -GNCH="$NCH" -GPE_LANES="$lanes" -GMAX_DIM="$MAXDIM" \
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
    "$AXI/src/axi_cut.sv" \
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
      echo "BUILD_FAIL lanes=$lanes (see $mdir.build.log)"; continue; }
  echo "KSWEEP_CONFIG lanes=$lanes maxdim=$MAXDIM nch=$NCH"
  "$mdir/tb_g6lc_ai_gemm_backend" +measure_k
done
echo "PASS tb_g6lc_ai_gemm_backend ksweep lanes=[$LANES_LIST] maxdim=$MAXDIM"
