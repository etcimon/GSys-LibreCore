#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Build + run tb_g6lc_sf_precision against one RTL tree.
#   SFP_TREE=production|hyp   (default production)
#   SFP_OUT=<dir>             (default /tmp/g6lc-sf-precision)
#   remaining args: -G overrides, then "--" then plusargs
# Prints the SF_WINDOW / SF_TOTAL lines; exit status is the simulation's.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
TREE="${SFP_TREE:-production}"
if [[ "$TREE" == hyp ]]; then
  A=build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu
  C=build-platform/workspace/hyp/hyp_redesign_core_8fo4
  V=$C/third_party/vendor/pulp-platform
  CFG=$C/core/include/config_pkg.sv
else
  A=corev_apu; V=vendor/pulp-platform; CFG=core/include/config_pkg.sv
fi
OUT="${SFP_OUT:-/tmp/g6lc-sf-precision}"; mkdir -p "$OUT"
G=(); while [[ $# -gt 0 && "$1" != "--" ]]; do G+=("$1"); shift; done; [[ "${1:-}" == "--" ]] && shift
"${VERILATOR:-verilator}" --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Werror-LATCH \
  -I"$V/axi/include" "${G[@]}" \
  "$V/axi/src/axi_pkg.sv" "$CFG" "$V/tech_cells_generic/src/rtl/tc_sram.sv" \
  "$A/coherence/g6lc_coherence_pkg.sv" "$A/coherence/g6lc_inval_bus.sv" \
  "$A/coherence/g6lc_snoop_filter.sv" "$A/coherence/g6lc_ooo_snoop_filter.sv" \
  "$A/coherence/g6lc_lr_sc_tracker.sv" "$A/coherence/g6lc_coherence_hub.sv" \
  -DL2TB_STATIC verif/tb/l2/tb_g6lc_l2.sv verif/tb/uncore/tb_g6lc_sf_precision.sv \
  --top-module tb_g6lc_sf_precision -Mdir "$OUT/obj" -o sim > "$OUT/build.log" 2>&1 \
  || { grep -m10 %Error "$OUT/build.log"; exit 2; }
"$OUT/obj/sim" "$@" 2>&1 | tee "$OUT/sim.log" | grep -E "^SF_|RTL_REVIEW_PASS|%Error|Fatal" | cut -c1-260
exit "${PIPESTATUS[0]}"
