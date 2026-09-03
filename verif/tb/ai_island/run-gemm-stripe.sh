#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Island GEMM vs N=2 stripe map (TB SRAM slave; not LiteDRAM, not Variane).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_GEMM_STRIPE_OUT:-/tmp/g6lc-ai-gemm-stripe}"
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
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
    -GNCH="$nch" \
    -I"$AXI/include" \
    -I"$CCELLS/include" \
    -I"$ROOT/corev_apu/include" \
    "$AXI/src/axi_pkg.sv" \
    "$AXI/src/axi_intf.sv" \
    "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
    "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
    "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot.sv" \
    "$ROOT/corev_apu/ai_island/g6lc_ai_tile_sram.sv" \
    "$ROOT/corev_apu/ai_island/g6lc_ai_gemm_seq.sv" \
    "$ROOT/verif/tb/ai_island/tb_g6lc_ai_gemm_stripe.sv" \
    --top-module tb_g6lc_ai_gemm_stripe \
    -Mdir "$mdir" -o tb_g6lc_ai_gemm_stripe
  "$mdir/tb_g6lc_ai_gemm_stripe"
}
DEFAULT_NCHS=(1 2)
# shellcheck source=nch-from-env.inc.sh
. "$(dirname "$0")/nch-from-env.inc.sh"
for nch in "${NCH_LIST[@]}"; do
  build_nch "$nch" "${OUT}-n${nch}"
done
echo "PASS tb_g6lc_ai_gemm_stripe nch=${NCH_LIST[*]}"
