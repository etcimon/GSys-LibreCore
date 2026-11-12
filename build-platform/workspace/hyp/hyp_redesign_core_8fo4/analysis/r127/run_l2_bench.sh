#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# L2 leaf bench (verif/tb/l2/run-l2-tb.sh) against the hyp8 APU tree, in the
# default and the posted-write / write-update configurations.
#   bash analysis/r127/run_l2_bench.sh [tag]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
TAG="${1:-r127}"
B="$ROOT/build-platform/workspace/build/r127-apu/l2-$TAG"; mkdir -p "$B"
export L2TB_RTL=build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu
# the bench is written for the pinned Verilator 5.008 (-Wall, warnings fatal); a newer local
# Verilator adds warning classes, so they are made non-fatal here (the pass token still decides)
export L2TB_EXTRA="${L2TB_EXTRA:--Wno-fatal}"
fail=0
run() { # name, env assignments...
  local name="$1"; shift
  ( cd "$ROOT" && env L2TB_OUT="$B/$name" "$@" timeout "${L2_BENCH_TIMEOUT:-1500}" bash verif/tb/l2/run-l2-tb.sh ) > "$B/$name.log" 2>&1
  local rc=$?
  local line; line="$(grep -E '\[l2-tb\] .*PASS' "$B/$name.log" | tail -1 | sed 's# — .*##' | cut -c1-120)"
  if [ $rc -eq 0 ] && [ -n "$line" ]; then echo "L2 $name: $line"
  else echo "L2 $name: FAIL rc=$rc $(grep -m1 -E '%Error|%Fatal|FAIL' "$B/$name.log" | cut -c1-150)"; fail=1; fi
}
run sim-default
run sim-posted   L2TB_POSTED_WRITES=1
run sim-wupdate  L2TB_WRITE_UPDATE=1
run sim-posted-wu L2TB_POSTED_WRITES=1 L2TB_WRITE_UPDATE=1
run units        L2TB_MODE=units
echo "L2_BENCH tag=$TAG fail=$fail"
exit $fail
