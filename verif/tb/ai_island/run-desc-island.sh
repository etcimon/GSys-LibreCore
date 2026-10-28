#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# N=2 island: crossing descriptor is ST_ERR with no AR; aligned zero desc is fetched.
# Does not define G6LC_AI_DRAM_ISLAND_PORT.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
AI_RTL="${G6LC_AI_RTL_DIR:-$ROOT/corev_apu/ai_island}"
. "$ROOT/verif/tb/ai_island/gemm-extra-sources.inc.sh"
AI_INC="${G6LC_AI_INC_DIR:-$ROOT/corev_apu/include}"
AI_SRC="${G6LC_AI_SRC_DIR:-$ROOT/corev_apu/src}"
AI_CVXIF="${G6LC_AI_CVXIF_DIR:-$ROOT/core/cvxif_g6lc_ai}"
POLICY_LEAVES=()
for leaf in g6lc_ai_policy_topology g6lc_ai_policy_publish; do
  if [[ -f "$AI_RTL/$leaf.sv" ]]; then POLICY_LEAVES+=("$AI_RTL/$leaf.sv"); fi
done
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi
OUT="${AI_DESC_ISLAND_OUT:-/tmp/g6lc-ai-desc-island}"
CCELLS="$ROOT/vendor/pulp-platform/common_cells"
AXI="$ROOT/vendor/pulp-platform/axi"
mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
  -I"$AXI/include" -I"$CCELLS/include" \
  -I"$ROOT/core/include" \
  -I"$AI_INC" \
  -I"$AI_RTL/include" \
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
  "$AI_INC/g6lc_ai_island_cfg_pkg.sv" \
  "$AI_RTL/include/g6lc_ai_desc_pkg.sv" \
  "$AI_RTL/include/g6lc_ai_fp_pkg.sv" \
  "$AI_RTL/include/g6lc_ai_policy_pkg.sv" \
  "$AI_RTL/g6lc_ai_addr_check.sv" \
  "$AI_RTL/g6lc_ai_cap_window.sv" \
  "$AI_RTL/g6lc_ai_desc_engine.sv" \
  "$AI_RTL/g6lc_ai_desc_fetch.sv" \
  "$AI_RTL/g6lc_ai_mem_store.sv" \
  "$AI_RTL/g6lc_ai_tile_sram.sv" \
  "$AI_RTL/g6lc_ai_pe_dot.sv" \
  "$AI_RTL/g6lc_ai_pe_dot_float.sv" \
  "$AI_RTL/g6lc_ai_pe_dot_float_pipe.sv" \
  "$AI_RTL/g6lc_ai_pe_dot_pipe.sv" \
  "$AI_RTL/g6lc_ai_policy_codec.sv" \
  "$AI_RTL/g6lc_ai_policy_subcode.sv" \
  "${POLICY_LEAVES[@]}" \
  "$AI_RTL/g6lc_ai_policy_steer.sv" \
  "$AI_RTL/g6lc_ai_gemm_seq.sv" \
  "${GEMM_EXTRA_SOURCES[@]}" \
  "$AI_RTL/g6lc_ai_mul_seq.sv" \
  "$AI_RTL/g6lc_ai_gemm_arplan.sv" \
  "$AI_RTL/g6lc_ai_dram_timing.sv" \
  "$AI_RTL/g6lc_ai_cpl_fifo.sv" \
  "$AI_RTL/g6lc_ai_cmd_fifo.sv" \
  "$AI_RTL/g6lc_ai_axi_cut.sv" \
  "$AI_RTL/g6lc_ai_inval_queue.sv" \
  "$AI_RTL/g6lc_ai_island_top.sv" \
  "$AI_RTL/g6lc_ai_island_apb.sv" \
  "$AI_SRC/g6lc_ai_dram_backend.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_desc_island.sv" \
  --top-module tb_g6lc_ai_desc_island \
  -Mdir "$OUT" -o tb_g6lc_ai_desc_island
"$OUT/tb_g6lc_ai_desc_island"
echo "PASS run-desc-island"
