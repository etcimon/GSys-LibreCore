#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Unit bench of the hyp8 APU invalidation bus (verif/tb/l2/tb_g6lc_inval_bus.sv)
# over a CORES x DEPTH sweep, with --assert, plus the bench's negative oracle.
#   bash analysis/r127/run_invbus_bench.sh [tag] [alternate g6lc_inval_bus.sv]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
COH="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/coherence"
TAG="${1:-r127}"; DUT="${2:-$COH/g6lc_inval_bus.sv}"
B="$ROOT/build-platform/workspace/build/r127-apu/invbus-$TAG"; mkdir -p "$B"
fail=0
for cores in 1 2 3 4; do
  for depth in 1 2 4; do
    M="$B/c$cores-d$depth"
    verilator --cc --main --exe --timing --assert --threads 1 -Wno-fatal \
      --top-module tb_g6lc_inval_bus -GCORES=$cores -GDEPTH=$depth --Mdir "$M" -o invbus \
      "$COH/g6lc_coherence_pkg.sv" "$DUT" "$ROOT/verif/tb/l2/tb_g6lc_inval_bus.sv" > "$M.build.log" 2>&1 \
      && make -s -C "$M" -f Vtb_g6lc_inval_bus.mk -j4 >> "$M.build.log" 2>&1 \
      || { echo "BUILD FAIL c=$cores d=$depth"; grep -m3 '%Error' "$M.build.log" | cut -c1-200; fail=1; continue; }
    "$M/invbus" > "$M.sim.log" 2>&1; rc=$?
    line="$(grep -m1 'INVBUS_PASS' "$M.sim.log" | cut -c1-150)"
    [ $rc -eq 0 ] && [ -n "$line" ] && echo "$line" || { echo "SIM FAIL c=$cores d=$depth rc=$rc $(grep -m1 -E 'Fatal|Error' "$M.sim.log" | cut -c1-160)"; fail=1; }
  done
done
# negative oracle on one geometry: must NOT pass
M="$B/c3-d2"
if "$M/invbus" +oracle_negative > "$M.neg.log" 2>&1 && grep -q INVBUS_PASS "$M.neg.log"; then
  echo "NEGATIVE ORACLE UNEXPECTEDLY PASSED"; fail=1
else
  echo "negative oracle detected: $(grep -m1 -E 'Fatal|INVBUS_' "$M.neg.log" | cut -c1-120)"
fi
echo "INVBUS_BENCH tag=$TAG fail=$fail"
exit $fail
