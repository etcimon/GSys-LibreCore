#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Class-0 N=2 striped SRAM smoke (not LiteDRAM, not Variane).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_DRAM_BACKEND_STRIPE_OUT:-/tmp/g6lc-ai-dram-backend-stripe}"
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
    "$AXI/src/axi_demux.sv" \
    "$AXI/src/axi_cut.sv" \
    "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
    "$ROOT/common/local/util/tc_sram_wrapper.sv" \
    "$ROOT/corev_apu/axi_mem_if/src/axi2mem.sv" \
    "$ROOT/common/local/util/sram.sv" \
    "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
    "$ROOT/corev_apu/src/g6lc_ai_dram_backend.sv" \
    "$ROOT/verif/tb/ai_island/tb_g6lc_ai_dram_backend_stripe.sv" \
    --top-module tb_g6lc_ai_dram_backend_stripe \
    -Mdir "$mdir" -o tb_g6lc_ai_dram_backend_stripe
  "$mdir/tb_g6lc_ai_dram_backend_stripe"
}

build_nch 2 "$OUT"
build_nch 4 "${OUT}-n4"
build_nch 8 "${OUT}-n8"
echo "PASS tb_g6lc_ai_dram_backend_stripe n2+n4+n8"
