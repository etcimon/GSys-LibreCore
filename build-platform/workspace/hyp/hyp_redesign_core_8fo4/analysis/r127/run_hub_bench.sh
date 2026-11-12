#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Unit bench of the hyp8 APU coherence hub (verif/tb/l2/tb_g6lc_coherence_hub.sv,
# top tb_g6lc_coherence_hub) with --assert, the scenario sets of
# verif/regress/remote/run_inval_review.py hub_review (repaired arm).
#   bash analysis/r127/run_hub_bench.sh [tag] [alternate g6lc_coherence_hub.sv]
# HUB_GEOMS="OT:NC ..." overrides the default "4:2 1:2 4:3 4:4".
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
APU="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu"
CORE="$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core"
COH="$APU/coherence"
TAG="${1:-r127}"; HUB="${2:-$COH/g6lc_coherence_hub.sv}"
B="$ROOT/build-platform/workspace/build/r127-apu/hub-$TAG"; mkdir -p "$B"
# the bench needs only the g6lc_l2_tb_pkg package of tb_g6lc_l2.sv (as hub_review extracts it)
awk '/^package g6lc_l2_tb_pkg;/{p=1} p{print} /^endpackage/{if(p){exit}}' \
  "$ROOT/verif/tb/l2/tb_g6lc_l2.sv" > "$B/types.sv"
grep -q '^endpackage' "$B/types.sv" || { echo "types.sv extraction failed"; exit 2; }
fail=0
for geom in ${HUB_GEOMS:-4:2 1:2 4:3 4:4}; do
  ot="${geom%%:*}"; nc="${geom##*:}"
  M="$B/ot$ot-nc$nc"
  verilator --cc --main --exe --timing --assert --threads 1 -Wno-fatal -Werror-LATCH \
    --top-module tb_g6lc_coherence_hub -GOT=$ot -GNC=$nc --Mdir "$M" -o hub-test \
    -I"$CORE/include" "$CORE/include/config_pkg.sv" "$COH/g6lc_coherence_pkg.sv" \
    "$COH/g6lc_inval_bus.sv" "$COH/g6lc_snoop_filter.sv" "$COH/g6lc_lr_sc_tracker.sv" "$HUB" \
    "$B/types.sv" "$ROOT/verif/tb/l2/tb_g6lc_coherence_hub.sv" > "$M.build.log" 2>&1 \
    && make -s -C "$M" -f Vtb_g6lc_coherence_hub.mk -j6 >> "$M.build.log" 2>&1 \
    || { echo "BUILD FAIL ot=$ot nc=$nc $(grep -m2 '%Error' "$M.build.log" | cut -c1-200)"; fail=1; continue; }
  if [ "$ot" = 4 ]; then scen="0 1 2 3 4 5 6 8 9"; else scen="0 1 2 7 8"; fi
  res=""
  for s in $scen; do
    "$M/hub-test" +scenario=$s > "$M.s$s.log" 2>&1; rc=$?
    if [ $rc -eq 0 ] && grep -q "HUB_PASS scenario=$s" "$M.s$s.log"; then res="$res $s:ok"
    else res="$res $s:FAIL($(grep -m1 -E 'Fatal|Error' "$M.s$s.log" | cut -c1-90))"; fail=1; fi
  done
  echo "HUB ot=$ot nc=$nc:$res"
done
echo "HUB_BENCH tag=$TAG fail=$fail"
exit $fail
