#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# 128-bit and 512-bit GEMM through g6lc_ai_dram_join. Does not define
# G6LC_AI_DRAM_ISLAND_PORT.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi
OUT="${AI_CLUSTER_DISPATCH_OUT:-/tmp/g6lc-ai-cluster-dispatch}"
CCELLS="$ROOT/vendor/pulp-platform/common_cells"
AXI="$ROOT/vendor/pulp-platform/axi"
mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
  -I"$AXI/include" -I"$CCELLS/include" \
  -I"$ROOT/core/include" \
  -I"$ROOT/corev_apu/include" \
  -I"$ROOT/corev_apu/ai_island/include" \
  "$ROOT/core/include/config_pkg.sv" \
  "$CCELLS/src/cf_math_pkg.sv" \
  "$CCELLS/src/lzc.sv" \
  "$CCELLS/src/counter.sv" \
  "$CCELLS/src/delta_counter.sv" \
  "$CCELLS/src/fifo_v3.sv" \
  "$CCELLS/src/spill_register_flushable.sv" \
  "$CCELLS/src/spill_register.sv" \
  "$CCELLS/src/deprecated/fifo_v2.sv" \
  "$CCELLS/src/stream_register.sv" \
  "$CCELLS/src/rr_arb_tree.sv" \
  "$CCELLS/src/onehot_to_bin.sv" \
  "$CCELLS/src/id_queue.sv" \
  "$AXI/src/axi_pkg.sv" \
  "$AXI/src/axi_intf.sv" \
  "$AXI/src/axi_id_prepend.sv" \
  "$AXI/src/axi_mux.sv" \
  "$AXI/src/axi_demux.sv" \
  "$AXI/src/axi_cut.sv" \
  "$AXI/src/axi_atop_filter.sv" \
  "$AXI/src/axi_err_slv.sv" \
  "$AXI/src/axi_dw_upsizer.sv" \
  "$AXI/src/axi_dw_downsizer.sv" \
  "$AXI/src/axi_dw_converter.sv" \
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
  "$ROOT/common/local/util/tc_sram_wrapper.sv" \
  "$ROOT/corev_apu/axi_mem_if/src/axi2mem.sv" \
  "$ROOT/common/local/util/sram.sv" \
  "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
  "$ROOT/corev_apu/ai_island/include/g6lc_ai_fp_pkg.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot_float.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot_float_pipe.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_tile_sram.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_gemm_seq.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_cluster_dispatch.sv" \
  "$ROOT/corev_apu/src/g6lc_ai_dram_backend.sv" \
  "$ROOT/corev_apu/src/g6lc_ai_dram_join.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_cluster_dispatch.sv" \
  --top-module tb_g6lc_ai_cluster_dispatch \
  -Mdir "$OUT" -o tb_g6lc_ai_cluster_dispatch
"$OUT/tb_g6lc_ai_cluster_dispatch"
echo "PASS run-cluster-dispatch"
