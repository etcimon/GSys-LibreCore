#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# hyp8 r68 iqleg leaf -- local (host Verilator) runner for the
# g6lc_iq_legal occupant-identity bench. The remote closure runs the same
# sources through run_hyp8_memory.py (HYP8_LEAF=iqleg); this script is
# the inner loop for a developer with a Verilator on PATH.
#
#   verif/regress/remote/hyp8/run_iqleg_leaf.sh [extra -D defines...]
#   verif/regress/remote/hyp8/run_iqleg_leaf.sh -DG6LC_MUT_IQLEG_STALE_OCCUPANT   # negative control
#
# Pass is the positive token HYP8_IQLEG_PASS on stdout; anything else is
# a fail (H3: a pass must be positive evidence).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HYP="${HYP_CORE_DIR:-$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core}"
OUT="${OUT_DIR:-${TMPDIR:-/tmp}/hyp8-iqleg}"
mkdir -p "$OUT"
SRCS=(
  "$HYP/include/config_pkg.sv"
  "$HYP/include/build_config_pkg.sv"
  "$HYP/include/g6lc_hyp_pkg.sv"
  "$HYP/include/g6lc64_hyp8_config_pkg.sv"
  "$HYP/include/riscv_pkg.sv"
  "$HYP/include/g6lc_core_pkg.sv"
  "$HYP/ooo/g6lc_ooo_pkg.sv"
  "$HYP/ooo/g6lc_iq_legal.sv"
  "$ROOT/verif/tb/core/tb_g6lc_hyp8_iqleg.sv"
)
verilator --cc --main --exe --timing --assert --threads 1 -Wno-fatal -Werror-LATCH \
  -DG6LC_FETCH_B "$@" -I"$HYP/include" -I"$HYP/ooo" \
  --top-module tb_g6lc_hyp8_iqleg --Mdir "$OUT/model" -o hyp8_iqleg "${SRCS[@]}" \
  > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
# the leaf runner's fatal classes, scanned the same way
if grep -E '%Warning-(WIDTH|IMPLICIT|MULTIDRIVEN|LATCH):|%Error' "$OUT/build.log"; then
  echo "iqleg: fatal diagnostic class in build log"; exit 1
fi
make -s -C "$OUT/model" -f Vtb_g6lc_hyp8_iqleg.mk -j2 >> "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
"$OUT/model/hyp8_iqleg" | tee "$OUT/sim.log"
grep -q 'HYP8_IQLEG_PASS' "$OUT/sim.log"
