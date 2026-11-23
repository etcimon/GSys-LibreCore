#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# hyp8 g6lc_thread_select CycQuantum (cycle-bounded SMT quantum) leaf --
# local (host Verilator) runner: positive (CYCQ=1024), +oracle_negative
# (raised switch floor -> must fail), and the -GCYCQ=0 build (no cycle bound:
# sparse-fetch residency is fetch-quantum long -> must fail
# TSEL_CYCQ_S1_RESIDENT_TOO_LONG).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HYP="${HYP_CORE_DIR:-$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core}"
OUT="${OUT_DIR:-${TMPDIR:-/tmp}/hyp8-tsel-cycq}"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
mkdir -p "$OUT"
SRCS=(
  "$HYP/include/config_pkg.sv"
  "$HYP/include/build_config_pkg.sv"
  "$HYP/include/g6lc_hyp_pkg.sv"
  "$HYP/include/g6lc64_hyp8_mc_config_pkg.sv"
  "$HYP/smt/g6lc_thread_select.sv"
  "$ROOT/verif/tb/core/tb_g6lc_thread_select_cycq.sv"
)
build() {
  verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-DECLFILENAME -Werror-LATCH \
    -DG6LC_FETCH_B -I"$HYP/include" \
    "${SRCS[@]}" --top-module tb_g6lc_thread_select_cycq -Mdir "$OUT/$1" -o tb ${2:-} > "$OUT/$1.build.log" 2>&1 \
    || { grep -m8 '%Error' "$OUT/$1.build.log"; exit 1; }
}
build pos
"$OUT/pos/tb" +ff_every=100 | tee "$OUT/pos.log" | grep -q "^PASS tb_g6lc_thread_select_cycq" || { echo "FAIL positive"; tail -3 "$OUT/pos.log"; exit 1; }
set +e
"$OUT/pos/tb" +ff_every=100 +oracle_negative > "$OUT/neg.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL oracle negative did not fail"; exit 1; }
build neg "-GCYCQ=0"
set +e
"$OUT/neg/tb" +ff_every=100 > "$OUT/neg0.log" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL -GCYCQ=0 build did not fail"; exit 1; }
grep -q "TSEL_CYCQ_S1_RESIDENT_TOO_LONG" "$OUT/neg0.log" || { echo "FAIL -GCYCQ=0 did not report TSEL_CYCQ_S1_RESIDENT_TOO_LONG"; tail -5 "$OUT/neg0.log"; exit 1; }
grep -q "TSEL_CYCQ_S" "$OUT/neg.log" || { echo "FAIL oracle negative did not report a TSEL_CYCQ fatal"; tail -5 "$OUT/neg.log"; exit 1; }
grep "^PASS" "$OUT/pos.log"
echo "PASS run_tsel_cycq_leaf (positive, oracle negative, -GCYCQ=0 cycle-bound-off caught)"
