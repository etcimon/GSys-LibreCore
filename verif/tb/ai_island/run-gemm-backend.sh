#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# GEMM golden C vs class-0 striped DRAM slave (not LiteDRAM, not Variane).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_GEMM_BACKEND_OUT:-/tmp/g6lc-ai-gemm-backend}"
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi
CCELLS="$ROOT/vendor/pulp-platform/common_cells"
AXI="$ROOT/vendor/pulp-platform/axi"
# Opt-in RTL measurement sweep. Unset / not "1" => byte-identical default run.
PLUSARGS=()
if [[ "${AI_GEMM_BACKEND_MEASURE:-0}" == "1" ]]; then
  PLUSARGS+=(+measure)
fi
build_nch() {
  local nch="$1"
  local dpf="$2"
  local mdir="$3"
  mkdir -p "$mdir"
  verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
    -GDOT_PIPE_FLOAT="$dpf" \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
    -GNCH="$nch" \
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
    -Mdir "$mdir" -o tb_g6lc_ai_gemm_backend
  "$mdir/tb_g6lc_ai_gemm_backend" ${PLUSARGS[@]+"${PLUSARGS[@]}"}
}
DEFAULT_NCHS=(1 2 4 8)
# shellcheck source=nch-from-env.inc.sh
. "$(dirname "$0")/nch-from-env.inc.sh"
for nch in "${NCH_LIST[@]}"; do
  build_nch "$nch" 0 "${OUT}-n${nch}"
  build_nch "$nch" 1 "${OUT}-n${nch}-dpf1"
done
echo "PASS tb_g6lc_ai_gemm_backend nch=${NCH_LIST[*]} dpf=0,1"
