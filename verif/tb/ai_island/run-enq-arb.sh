#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# g6lc_ai_enq_arb leaf: positive run, +oracle_negative (must fail), and the
# G6LC_MUT_ENQ_ARB_FIXED mutation (fixed priority: must fail STARVED/UNFAIR).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
OUT="${AI_ENQ_ARB_OUT:-/tmp/g6lc-ai-enq-arb}"
mkdir -p "$OUT"
build() {
  verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    "$ROOT/corev_apu/ai_island/g6lc_ai_enq_arb.sv" \
    "$ROOT/verif/tb/ai_island/tb_g6lc_ai_enq_arb.sv" \
    --top-module tb_g6lc_ai_enq_arb -Mdir "$OUT/$1" -o tb ${2:-} > "$OUT/$1.build.log" 2>&1
}
build pos
"$OUT/pos/tb" | tee "$OUT/pos.log" | grep -q "^PASS tb_g6lc_ai_enq_arb" || { echo "FAIL positive"; exit 1; }
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
grep -q "ORACLE_NEGATIVE" "$OUT/neg.log" || { echo "FAIL oracle negative did not fire"; exit 1; }
build mut "+define+G6LC_MUT_ENQ_ARB_FIXED"
"$OUT/mut/tb" > "$OUT/mut.log" 2>&1
grep -qE "STARVED|UNFAIR" "$OUT/mut.log" || { echo "FAIL mutation G6LC_MUT_ENQ_ARB_FIXED not caught"; exit 1; }
set -e
echo "PASS run-enq-arb (positive, oracle negative, fixed-priority mutation caught)"
