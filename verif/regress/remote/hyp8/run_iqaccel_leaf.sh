#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# hyp8 rfix131a ACCEL-head leaf -- local (host Verilator) runner for the
# g6lc_iq commit-head/port-0 contract on the ACCEL (Ara/RVV) functional unit.
# Mirrors tb_g6lc_iq_cvxif_head for the accelerator class ported in
# RFIX-131a-18 (commit 509f4767). Positive token PASS tb_g6lc_iq_accel_head;
# the G6LC_MUT_ACCEL_NOHEAD mutant must fail IQ_ACCEL_HEAD (negative control).
#
#   verif/regress/remote/hyp8/run_iqaccel_leaf.sh
#   verif/regress/remote/hyp8/run_iqaccel_leaf.sh -DG6LC_MUT_ACCEL_NOHEAD    # negative control
#
# Pass is the positive token on stdout; anything else is a fail.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HYP="${HYP_CORE_DIR:-$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core}"
APU="${APU_ROOT:-$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4}"
OUT="${OUT_DIR:-${TMPDIR:-/tmp}/hyp8-iqaccel}"
mkdir -p "$OUT"
SRCS=(
  "$HYP/include/config_pkg.sv"
  "$HYP/include/build_config_pkg.sv"
  "$HYP/include/g6lc_hyp_pkg.sv"
  "$HYP/include/g6lc64_hyp8_config_pkg.sv"
  "$HYP/include/riscv_pkg.sv"
  "$HYP/include/g6lc_core_pkg.sv"
  "$HYP/ooo/g6lc_ooo_pkg.sv"
  "$HYP/ooo/g6lc_iq_payload.sv"
  "$HYP/ooo/g6lc_iq_xbar.sv"
  "$HYP/ooo/g6lc_iq_bank.sv"
  "$HYP/ooo/g6lc_iq_legal.sv"
  "$HYP/ooo/g6lc_iq_arb.sv"
  "$HYP/ooo/g6lc_iq.sv"
  "$APU/verif/tb/core/tb_g6lc_iq_accel_head.sv"
)
build() {
  local name="$1"; shift
  verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
    -Wno-UNOPTFLAT -Werror-LATCH -DG6LC_FETCH_B "$@" \
    -I"$HYP/include" -I"$HYP/ooo" -I"$HYP/include/fetch_B" \
    --top-module tb_g6lc_iq_accel_head --Mdir "$OUT/$name" -o tb "${SRCS[@]}" \
    > "$OUT/$name.build.log" 2>&1
}
# positive
build pos
set +e
"$OUT/pos/tb" > "$OUT/pos.log" 2>&1
rc=$?
set -e
grep -q 'PASS tb_g6lc_iq_accel_head' "$OUT/pos.log" || { echo "FAIL positive (rc=$rc)"; cat "$OUT/pos.log"; tail -30 "$OUT/pos.build.log"; exit 1; }
echo "PASS positive"
# oracle negative: flips every expect, must fatal on the first held check.
# Accept the bench fatal OR the design's own head-only legality assertion.
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
set -e
if grep -q 'PASS tb_g6lc_iq_accel_head' "$OUT/neg.log"; then
  echo "FAIL oracle negative reached PASS"; cat "$OUT/neg.log"; exit 1
fi
grep -qE 'IQ_ACCEL_HEAD|ORACLE_NEGATIVE|iv never rose|Assertion failed' "$OUT/neg.log" \
  || { echo "FAIL oracle negative did not fire"; cat "$OUT/neg.log"; exit 1; }
echo "PASS oracle negative"
# mutation: ACCEL not head-only -> must not reach PASS. Caught either by the
# bench held-check (IQ_ACCEL_HEAD) or the design's g6lc_r68_iqleg_head_only
# assertion, whichever fires first.
build mut -DG6LC_MUT_ACCEL_NOHEAD
set +e
"$OUT/mut/tb" > "$OUT/mut.log" 2>&1
set -e
if grep -q 'PASS tb_g6lc_iq_accel_head' "$OUT/mut.log"; then
  echo "FAIL mutation G6LC_MUT_ACCEL_NOHEAD reached PASS"; cat "$OUT/mut.log"; exit 1
fi
grep -qE 'IQ_ACCEL_HEAD|g6lc_r68_iqleg_head_only|Assertion failed|\$fatal' "$OUT/mut.log" \
  || { echo "FAIL mutation G6LC_MUT_ACCEL_NOHEAD not caught"; cat "$OUT/mut.log"; tail -30 "$OUT/mut.build.log"; exit 1; }
echo "PASS mutation caught"
echo "PASS run-iqaccel-leaf (positive, oracle negative, no-head mutation caught)"
