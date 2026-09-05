#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Standalone Verilator smoke for Xg6lcai island with EnableDmaFetch=1.
# Exercises descriptor DMA fetch, GEMM completion, and policy PMU words.
#
# Usage:
#   bash verif/regress/ai-island-dma.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ -d /root/tools/verilator-v5.008/bin ]]; then
  export PATH="/root/tools/verilator-v5.008/bin:${PATH}"
  export VERILATOR_ROOT="${VERILATOR_ROOT:-/root/tools/verilator-v5.008/share/verilator}"
fi

log() { echo "[ai-island-dma] $*"; }
command -v verilator >/dev/null || { log "need verilator"; exit 1; }
command -v g++ >/dev/null || { log "need g++"; exit 1; }

OUT="${AI_ISLAND_DMA_OUT:-work-ver-ai-island-dma}"
rm -rf "$OUT"
mkdir -p "$OUT"

log "verilate → $OUT (verilator $(verilator --version 2>/dev/null | head -1))"
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
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

log "run"
set +e
"$OUT/tb_g6lc_ai_island_dma" | tee "$OUT/run.log"
rc=${PIPESTATUS[0]}
set -e
if grep -q '\*\*\* SUCCESS \*\*\*' "$OUT/run.log" && [[ "$rc" -eq 0 ]]; then
  log "PASS"
  exit 0
fi
log "FAIL rc=$rc"
tail -40 "$OUT/run.log" || true
exit 1
