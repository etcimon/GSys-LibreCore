#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# DramClass=2 must $error and must not elaborate a PHY. The message is the pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi
OUT="${AI_DRAM_CLASS2_OUT:-/tmp/g6lc-ai-dram-class2}"
CCELLS="$ROOT/vendor/pulp-platform/common_cells"
AXI="$ROOT/vendor/pulp-platform/axi"
mkdir -p "$OUT"
verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
  -I"$AXI/include" -I"$CCELLS/include" \
  -I"$ROOT/corev_apu/include" \
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
  "$AXI/src/axi_pkg.sv" \
  "$AXI/src/axi_intf.sv" \
  "$AXI/src/axi_demux.sv" \
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
  "$ROOT/common/local/util/tc_sram_wrapper.sv" \
  "$ROOT/corev_apu/axi_mem_if/src/axi2mem.sv" \
  "$ROOT/common/local/util/sram.sv" \
  "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
  "$ROOT/corev_apu/src/g6lc_ai_dram_channels.sv" \
  "$ROOT/corev_apu/src/g6lc_ai_litedram_wrap.sv" \
  "$ROOT/corev_apu/src/g6lc_ai_dram_backend.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_dram_class2.sv" \
  --top-module tb_g6lc_ai_dram_class2 \
  -Mdir "$OUT" -o tb_g6lc_ai_dram_class2
set +e
"$OUT/tb_g6lc_ai_dram_class2" >"$OUT/class2.log" 2>&1
set -e
grep -q "DramClass=2 (LPDDR5) has no PHY" "$OUT/class2.log"
echo "PASS run-dram-class2"
