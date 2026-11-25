#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# hyp8 g6lc_zicclsm OoO TID-matched passthrough + unchecked-split replay leaf:
#   1. positive: PASS tb_g6lc_zicclsm_hyp8
#   2. +oracle_negative: fails ZICCLSM_OOO_TID_SWALLOW
#   3. -DG6LC_MUT_ZICCLSM_TID_SWALLOW: fails ZICCLSM_OOO_TID_SWALLOW (RC4)
#   4. -DG6LC_MUT_ZICCLSM_UNCHECKED_SPLIT: fails ZICCLSM_UNCHECKED_DEADLOCK (RC6)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HYP="${HYP_CORE_DIR:-$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core}"
OUT="${OUT_DIR:-${TMPDIR:-/tmp}/hyp8-zicclsm}"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
mkdir -p "$OUT"
SRCS=(
  "$HYP/include/config_pkg.sv"
  "$HYP/include/build_config_pkg.sv"
  "$HYP/include/g6lc_hyp_pkg.sv"
  "$HYP/include/g6lc64_hyp8_mc_config_pkg.sv"
  "$HYP/include/riscv_pkg.sv"
  "$HYP/include/g6lc_core_pkg.sv"
  "$HYP/g6lc_zicclsm.sv"
  "$ROOT/verif/tb/core/tb_g6lc_zicclsm_hyp8.sv"
)
build() {
  verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-DECLFILENAME -Werror-LATCH \
    -DG6LC_FETCH_B -I"$HYP/include" \
    "${SRCS[@]}" --top-module tb_g6lc_zicclsm_hyp8 -Mdir "$OUT/$1" -o tb ${2:-} > "$OUT/$1.build.log" 2>&1 \
    || { grep -m10 '%Error' "$OUT/$1.build.log" || tail -20 "$OUT/$1.build.log"; exit 1; }
}
build pos
"$OUT/pos/tb" | tee "$OUT/pos.log" | grep -q "^PASS tb_g6lc_zicclsm_hyp8" \
  || { echo "FAIL positive"; tail -5 "$OUT/pos.log"; exit 1; }
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
grep -q "ZICCLSM_OOO_TID_SWALLOW" "$OUT/neg.log" \
  || { echo "FAIL oracle negative did not fire"; tail -5 "$OUT/neg.log"; exit 1; }
build mut "-DG6LC_MUT_ZICCLSM_TID_SWALLOW"
"$OUT/mut/tb" > "$OUT/mut.log" 2>&1
grep -q "ZICCLSM_OOO_TID_SWALLOW" "$OUT/mut.log" \
  || { echo "FAIL mutation G6LC_MUT_ZICCLSM_TID_SWALLOW not caught"; tail -5 "$OUT/mut.log"; exit 1; }
build mut_rc6 "-DG6LC_MUT_ZICCLSM_UNCHECKED_SPLIT"
"$OUT/mut_rc6/tb" > "$OUT/mut_rc6.log" 2>&1
grep -q "ZICCLSM_UNCHECKED_DEADLOCK" "$OUT/mut_rc6.log" \
  || { echo "FAIL mutation G6LC_MUT_ZICCLSM_UNCHECKED_SPLIT not caught"; tail -5 "$OUT/mut_rc6.log"; exit 1; }
set -e
grep "^PASS" "$OUT/pos.log"
echo "PASS run_zicclsm_leaf (positive, oracle negative, tid-swallow & unchecked-split mutations caught)"
