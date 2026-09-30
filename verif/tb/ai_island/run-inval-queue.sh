#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# g6lc_ai_inval_queue leaf: positive run, +oracle_negative (must fail), and the
# G6LC_MUT_INVAL_AT_AW mutation (inval before B: must fail INVAL_BEFORE_LANDED).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
OUT="${AI_INVAL_QUEUE_OUT:-/tmp/g6lc-ai-inval-queue}"
mkdir -p "$OUT"
build() { # tag, extra verilator args
  verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    "$ROOT/corev_apu/ai_island/g6lc_ai_inval_queue.sv" \
    "$ROOT/verif/tb/ai_island/tb_g6lc_ai_inval_queue.sv" \
    --top-module tb_g6lc_ai_inval_queue -Mdir "$OUT/$1" -o tb ${2:-} > "$OUT/$1.build.log" 2>&1
}
build pos
"$OUT/pos/tb" | tee "$OUT/pos.log" | grep -q "^PASS tb_g6lc_ai_inval_queue" || { echo "FAIL positive"; exit 1; }
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
grep -q "ORACLE_NEGATIVE" "$OUT/neg.log" || { echo "FAIL oracle negative did not fire"; exit 1; }
build mut "+define+G6LC_MUT_INVAL_AT_AW"
"$OUT/mut/tb" > "$OUT/mut.log" 2>&1
grep -q "INVAL_BEFORE_LANDED" "$OUT/mut.log" || { echo "FAIL mutation G6LC_MUT_INVAL_AT_AW not caught"; exit 1; }
set -e
echo "PASS run-inval-queue (positive, oracle negative, inval-at-AW mutation caught)"
