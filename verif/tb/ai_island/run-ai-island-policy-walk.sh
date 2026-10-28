#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Run a multi-job policy walk through the DMA-enabled island top.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

AI_RTL="${G6LC_AI_RTL_DIR:-$ROOT/corev_apu/ai_island}"
. "$ROOT/verif/tb/ai_island/gemm-extra-sources.inc.sh"
AI_INC="${G6LC_AI_INC_DIR:-$ROOT/corev_apu/include}"
AI_SRC="${G6LC_AI_SRC_DIR:-$ROOT/corev_apu/src}"
AI_CVXIF="${G6LC_AI_CVXIF_DIR:-$ROOT/core/cvxif_g6lc_ai}"
POLICY_LEAVES=()
for leaf in g6lc_ai_policy_topology g6lc_ai_policy_publish; do
  if [[ -f "$AI_RTL/$leaf.sv" ]]; then POLICY_LEAVES+=("$AI_RTL/$leaf.sv"); fi
done

if [[ -z "${G6LC_FORCE_SYSTEM_VERILATOR:-}" && -d /root/tools/verilator-v5.008/bin ]]; then
  export PATH="/root/tools/verilator-v5.008/bin:${PATH}"
  export VERILATOR_ROOT="${VERILATOR_ROOT:-/root/tools/verilator-v5.008/share/verilator}"
fi

command -v verilator >/dev/null || { echo "[ai-island-policy-walk] need verilator"; exit 1; }
command -v g++ >/dev/null || { echo "[ai-island-policy-walk] need g++"; exit 1; }

OUT="${AI_ISLAND_POLICY_WALK_OUT:-work-ver-ai-island-policy-walk}"
rm -rf "$OUT"
mkdir -p "$OUT"

python3 verif/tb/ai_island/gen_policy_walk.py --out "$OUT"
NUM_JOBS=$(python3 -c "import json; print(json.load(open('$OUT/walk.json'))['num_jobs'])")
JOB_STRIDE=$(python3 -c "import json; print(json.load(open('$OUT/walk.json'))['job_stride'])")

echo "[ai-island-policy-walk] verilate → $OUT (verilator $(verilator --version 2>/dev/null | head -1))"
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
  -I"$AI_INC" \
  -I"$AI_RTL/include" \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
  -I"$ROOT/vendor/pulp-platform/axi/include" \
  -I"$ROOT/vendor/pulp-platform/common_cells/include" \
  -I"$ROOT/core/include" \
  -I"$ROOT/corev_apu/include" \
  -I"$ROOT/corev_apu/ai_island/include" \
  "$ROOT/vendor/pulp-platform/common_cells/src/cf_math_pkg.sv" \
  "$ROOT/vendor/pulp-platform/common_cells/src/lzc.sv" \
  "$ROOT/vendor/pulp-platform/common_cells/src/counter.sv" \
  "$ROOT/vendor/pulp-platform/common_cells/src/delta_counter.sv" \
  "$ROOT/vendor/pulp-platform/common_cells/src/fifo_v3.sv" \
  "$ROOT/vendor/pulp-platform/common_cells/src/spill_register_flushable.sv" \
  "$ROOT/vendor/pulp-platform/common_cells/src/spill_register.sv" \
  "$ROOT/vendor/pulp-platform/common_cells/src/rr_arb_tree.sv" \
  "$ROOT/vendor/pulp-platform/axi/src/axi_pkg.sv" \
  "$ROOT/vendor/pulp-platform/axi/src/axi_intf.sv" \
  "$ROOT/core/include/config_pkg.sv" \
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
  "$ROOT/common/local/util/tc_sram_wrapper.sv" \
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
  "$AI_RTL/g6lc_ai_pe_dot_pipe.sv" \
  "$AI_RTL/g6lc_ai_pe_dot_float.sv" \
  "$AI_RTL/g6lc_ai_pe_dot_float_pipe.sv" \
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
  "$AI_RTL/g6lc_ai_axi_cut.sv" \
  "$AI_RTL/g6lc_ai_cmd_fifo.sv" \
  "$AI_RTL/g6lc_ai_inval_queue.sv" \
  "$AI_RTL/g6lc_ai_cluster_dispatch.sv" \
  "$AI_RTL/g6lc_ai_island_top.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_island_dma.sv" \
  --top-module tb_g6lc_ai_island_dma \
  -Mdir "$OUT" -o tb_g6lc_ai_island_dma \
  --exe "$ROOT/verif/tb/ai_island/ai_island_dma_main.cpp"

echo "[ai-island-policy-walk] run $NUM_JOBS jobs"
"$OUT/tb_g6lc_ai_island_dma" "+num_jobs=$NUM_JOBS" "+job_stride=$JOB_STRIDE" "+walk_file=$OUT/walk.hex"

echo "[ai-island-policy-walk] PASS"
