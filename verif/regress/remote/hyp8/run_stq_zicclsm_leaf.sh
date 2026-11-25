#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# hyp8 store_buffer multi-beat Zicclsm store commit leaf (`RC5`):
#   1. positive: PASS tb_g6lc_stq_zicclsm_hyp8 (with --assert)
#   2. +oracle_negative: fails STQ_ZICCLSM_COMMIT_DEADLOCK
#   3. -DG6LC_MUT_STQ_ZICCLSM_SINGLE_BEAT (both --assert and +verilator+noassert):
#      fails age-order assert / STQ_ZICCLSM_COMMIT_LOST
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HYP="${HYP_CORE_DIR:-$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core}"
OUT="${OUT_DIR:-${TMPDIR:-/tmp}/hyp8-stq-zicclsm}"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
mkdir -p "$OUT"
SRCS=(
  "$HYP/include/config_pkg.sv"
  "$HYP/include/build_config_pkg.sv"
  "$HYP/include/g6lc_hyp_pkg.sv"
  "$HYP/include/g6lc64_hyp8_mc_config_pkg.sv"
  "$HYP/include/riscv_pkg.sv"
  "$HYP/include/g6lc_core_pkg.sv"
  "$HYP/ooo/g6lc_ooo_pkg.sv"
  "$HYP/stb_insert.sv"
  "$HYP/stb_commit.sv"
  "$HYP/stb_drain.sv"
  "$HYP/stb_fwd.sv"
  "$HYP/store_buffer.sv"
  "$ROOT/verif/tb/core/tb_g6lc_stq_zicclsm_hyp8.sv"
)
build() {
  verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-DECLFILENAME -Werror-LATCH \
    -DG6LC_FETCH_B -I"$HYP/include" -I"$HYP/ooo" \
    "${SRCS[@]}" --top-module tb_g6lc_stq_zicclsm_hyp8 -Mdir "$OUT/$1" -o tb ${2:-} > "$OUT/$1.build.log" 2>&1 \
    || { grep -m10 '%Error' "$OUT/$1.build.log" || tail -20 "$OUT/$1.build.log"; exit 1; }
}
build pos
"$OUT/pos/tb" | tee "$OUT/pos.log" | grep -q "^PASS tb_g6lc_stq_zicclsm_hyp8" \
  || { echo "FAIL positive"; tail -8 "$OUT/pos.log"; exit 1; }
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
grep -q "STQ_ZICCLSM_" "$OUT/neg.log" \
  || { echo "FAIL oracle negative did not fire"; tail -5 "$OUT/neg.log"; exit 1; }
build mut "-DG6LC_MUT_STQ_ZICCLSM_SINGLE_BEAT"
"$OUT/mut/tb" +verilator+noassert > "$OUT/mut.log" 2>&1
grep -q "STQ_ZICCLSM_" "$OUT/mut.log" \
  || { echo "FAIL mutation G6LC_MUT_STQ_ZICCLSM_SINGLE_BEAT not caught"; tail -5 "$OUT/mut.log"; exit 1; }
set -e
grep "^PASS" "$OUT/pos.log"
echo "PASS run_stq_zicclsm_leaf (positive, oracle negative, single-beat mutation caught)"
