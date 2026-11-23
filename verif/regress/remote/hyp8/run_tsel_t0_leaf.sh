#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# hyp8 g6lc_thread_select `li t0` deferral leaf -- local (host Verilator) runner: positive, +oracle_negative
# (must fail TSEL_T0_S1_PEER_STARVED) and the G6LC_MUT_SMT_T0_DEFER_UNBOUNDED mutation (the pre-fix gate: the
# quantum switch is suppressed at every fetch -- must fail TSEL_T0_S1_PEER_STARVED with switches=0).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HYP="${HYP_CORE_DIR:-$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core}"
OUT="${OUT_DIR:-${TMPDIR:-/tmp}/hyp8-tsel-t0}"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
mkdir -p "$OUT"
SRCS=(
  "$HYP/include/config_pkg.sv"
  "$HYP/include/build_config_pkg.sv"
  "$HYP/include/g6lc_hyp_pkg.sv"
  "$HYP/include/g6lc64_hyp8_mc_config_pkg.sv"
  "$HYP/smt/g6lc_thread_select.sv"
  "$ROOT/verif/tb/core/tb_g6lc_thread_select_t0.sv"
)
build() {
  verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-DECLFILENAME -Werror-LATCH \
    -DG6LC_FETCH_B -I"$HYP/include" \
    "${SRCS[@]}" --top-module tb_g6lc_thread_select_t0 -Mdir "$OUT/$1" -o tb ${2:-} > "$OUT/$1.build.log" 2>&1 \
    || { grep -m8 '%Error' "$OUT/$1.build.log"; exit 1; }
}
build pos
"$OUT/pos/tb" | tee "$OUT/pos.log" | grep -q "^PASS tb_g6lc_thread_select_t0" || { echo "FAIL positive"; tail -3 "$OUT/pos.log"; exit 1; }
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
grep -q "TSEL_T0_S1_PEER_STARVED" "$OUT/neg.log" || { echo "FAIL oracle negative did not fire"; exit 1; }
build mut "-DG6LC_MUT_SMT_T0_DEFER_UNBOUNDED"
"$OUT/mut/tb" > "$OUT/mut.log" 2>&1
grep -q "TSEL_T0_S1_PEER_STARVED switches=0 " "$OUT/mut.log" || { echo "FAIL mutation G6LC_MUT_SMT_T0_DEFER_UNBOUNDED not caught"; tail -5 "$OUT/mut.log"; exit 1; }
set -e
grep "^PASS" "$OUT/pos.log"
echo "PASS run_tsel_t0_leaf (positive, oracle negative, unbounded-deferral mutation caught)"
