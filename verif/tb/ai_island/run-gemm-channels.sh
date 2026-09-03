#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# GEMM golden C vs class-1 LiteDRAM N=1 identity + N=2/4/8 stripe (not Variane).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_GEMM_CHANNELS_OUT:-/tmp/g6lc-ai-gemm-channels}"
CORE="$ROOT/corev_apu/ai_island/generated/gateware/litedram_core.v"
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi
if [[ ! -f "$CORE" ]]; then
  echo "SKIP no generated litedram_core.v"
  exit 0
fi
CCELLS="$ROOT/vendor/pulp-platform/common_cells"
AXI="$ROOT/vendor/pulp-platform/axi"

build_nch() {
  local nch="$1"
  local mdir="$2"
  mkdir -p "$mdir"
  verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
    +define+G6LC_HAVE_LITEDRAM \
    -GNCH="$nch" \
    -I"$AXI/include" \
    -I"$CCELLS/include" \
    -I"$ROOT/corev_apu/include" \
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
    "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
    "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
    "$ROOT/corev_apu/ai_island/g6lc_ai_cap_window.sv" \
    "$ROOT/corev_apu/src/g6lc_ai_litedram_wrap.sv" \
    "$ROOT/corev_apu/src/g6lc_ai_dram_channels.sv" \
    "$CORE" \
    "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot.sv" \
    "$ROOT/corev_apu/ai_island/g6lc_ai_tile_sram.sv" \
    "$ROOT/corev_apu/ai_island/g6lc_ai_gemm_seq.sv" \
    "$ROOT/verif/tb/ai_island/tb_g6lc_ai_gemm_channels.sv" \
    --top-module tb_g6lc_ai_gemm_channels \
    -Mdir "$mdir" -o tb_g6lc_ai_gemm_channels
  "$mdir/tb_g6lc_ai_gemm_channels"
}

DEFAULT_NCHS=(1 2 4 8)
# shellcheck source=nch-from-env.inc.sh
. "$(dirname "$0")/nch-from-env.inc.sh"
for nch in "${NCH_LIST[@]}"; do
  build_nch "$nch" "${OUT}-n${nch}"
done
echo "PASS tb_g6lc_ai_gemm_channels nch=${NCH_LIST[*]}"
