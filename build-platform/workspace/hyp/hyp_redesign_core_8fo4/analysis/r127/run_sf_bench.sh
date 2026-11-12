#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Unit bench of the hyp8 APU snoop filter (verif/tb/uncore/tb_g6lc_snoop_filter.sv),
# scenarios 0/1/2 plus the injected-oracle trials, with --assert.
#   bash analysis/r127/run_sf_bench.sh [tag] [alternate g6lc_snoop_filter.sv]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
COH="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/coherence"
CORE="$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core"
TAG="${1:-r127}"; DUT="${2:-$COH/g6lc_snoop_filter.sv}"
B="$ROOT/build-platform/workspace/build/r127-apu/sf-$TAG"; mkdir -p "$B"
fail=0
for geom in 2:4 3:8 4:16; do
  nc="${geom%%:*}"; ne="${geom##*:}"; M="$B/c$nc-e$ne"
  if ! { verilator --cc --main --exe --timing --assert --threads 1 -Wno-fatal -Wno-TIMESCALEMOD -Werror-LATCH --top-module tb_g6lc_snoop_filter -GNR_CORES=$nc -GNR_ENTRIES=$ne --Mdir "$M" -o sf-test -I"$CORE/include" "$CORE/include/config_pkg.sv" "$COH/g6lc_coherence_pkg.sv" "$DUT" "$ROOT/verif/tb/uncore/tb_g6lc_snoop_filter.sv" > "$M.build.log" 2>&1 && make -s -C "$M" -f Vtb_g6lc_snoop_filter.mk -j4 >> "$M.build.log" 2>&1; }; then
    echo "SF c=$nc e=$ne BUILD FAIL $(grep -m2 '%Error' "$M.build.log" | cut -c1-160)"; fail=1; continue
  fi
  res=""
  for s in 0 1 2; do
    "$M/sf-test" +scenario=$s > "$M.s$s.log" 2>&1; rc=$?
    if [ $rc -eq 0 ] && grep -q "RTL_REVIEW_PASS sf scenario=$s" "$M.s$s.log"; then res="$res $s:ok"; else res="$res $s:FAIL"; fail=1; fi
  done
  for s in 0 1; do
    "$M/sf-test" +scenario=$s +oracle_negative > "$M.n$s.log" 2>&1
    res="$res neg$s:$(grep -m1 -oE 'SF_NEGATIVE_CAUGHT|SF_NEGATIVE_NOT_DETECTED|RTL_REVIEW_PASS' "$M.n$s.log" | head -1)"
  done
  echo "SF c=$nc e=$ne:$res"
done
echo "SF_BENCH tag=$TAG fail=$fail"
exit $fail
