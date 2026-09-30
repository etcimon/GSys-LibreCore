#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Elaboration check of g6lc_ai_island_top with Clusters = 1 / 2 / 4 at a reduced geometry
# (g6lc_ai_cluster_dispatch inside the island for 2 and 4).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
OUT="${AI_ISLAND_CLUSTERS_OUT:-/tmp/g6lc-ai-island-clusters}"
CCELLS="$ROOT/vendor/pulp-platform/common_cells"
AXI="$ROOT/vendor/pulp-platform/axi"
mkdir -p "$OUT"
for n in 1 2 4; do
  if ! verilator --lint-only -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-DECLFILENAME \
    -I"$AXI/include" -I"$CCELLS/include" -I"$ROOT/corev_apu/include" -I"$ROOT/corev_apu/ai_island/include" \
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
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
  "$ROOT/common/local/util/tc_sram_wrapper.sv" \
  "$ROOT/corev_apu/axi_mem_if/src/axi2mem.sv" \
  "$ROOT/common/local/util/sram.sv" \
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
  "$ROOT/corev_apu/ai_island/g6lc_ai_policy_subcode.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_policy_steer.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_gemm_seq.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_cluster_dispatch.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_dram_timing.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_cpl_fifo.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_cmd_fifo.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_axi_cut.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_inval_queue.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_island_top.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_island_apb.sv" \
  "$ROOT/corev_apu/src/g6lc_ai_dram_backend.sv" \
  "$ROOT/verif/tb/ai_island/lint_g6lc_ai_island_clusters.sv" \
  --top-module lint_g6lc_ai_island_clusters -GCLUSTERS=$n > "$OUT/lint-clusters-$n.log" 2>&1; then
    grep -E "%Error" "$OUT/lint-clusters-$n.log" | head -5
    echo "FAIL g6lc_ai_island_top Clusters=$n"; exit 1
  fi
  echo "elaborates: g6lc_ai_island_top Clusters=$n ($(grep -c '%Warning' "$OUT/lint-clusters-$n.log") warnings)"
done
echo "PASS run-island-clusters-lint"
