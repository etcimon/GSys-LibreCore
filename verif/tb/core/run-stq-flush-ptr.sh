#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# store_buffer flush/commit pointer leaf (T35): positive, +oracle_negative (must fail), and the
# G6LC_MUT_STQ_FLUSH_WP_Q mutation (A141: a leaving entry keeps its age bits; the RTL's
# own spec_order_cleared must trip — before A141 it was the pre-fix write pointer).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
OUT="${STQ_FLUSH_PTR_OUT:-/tmp/g6lc-stq-flush-ptr}"
mkdir -p "$OUT"
SRCS=(
  "$ROOT/core/include/config_pkg.sv"
  "$ROOT/core/include/g6lc64_ooo_config_pkg.sv"
  "$ROOT/core/include/riscv_pkg.sv"
  "$ROOT/core/include/ariane_pkg.sv"
  "$ROOT/core/ooo/g6lc_ooo_pkg.sv"
  "$ROOT/core/store_buffer.sv"
  "$ROOT/verif/tb/core/tb_g6lc_stq_flush_ptr.sv"
)
build() {
  verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -I"$ROOT/core/include" -I"$ROOT/core/ooo" \
    "${SRCS[@]}" --top-module tb_g6lc_stq_flush_ptr -Mdir "$OUT/$1" -o tb ${2:-} > "$OUT/$1.build.log" 2>&1
}
build pos
"$OUT/pos/tb" | tee "$OUT/pos.log" | grep -q "^PASS tb_g6lc_stq_flush_ptr" || { echo "FAIL positive"; exit 1; }
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
grep -q "STQ_\|ORACLE_NEGATIVE" "$OUT/neg.log" || { echo "FAIL oracle negative did not fire"; exit 1; }
build mut "+define+G6LC_MUT_STQ_FLUSH_WP_Q"
"$OUT/mut/tb" > "$OUT/mut.log" 2>&1
grep -q "STQ_PTR_AGREE\|STQ_HEAD_IS_ARRIVAL\|stale age bit\|pointers rp=\|scoreboard slot is not live" "$OUT/mut.log" || { echo "FAIL mutation G6LC_MUT_STQ_FLUSH_WP_Q not caught"; cat "$OUT/mut.log"; exit 1; }
set -e
echo "PASS run-stq-flush-ptr (positive, oracle negative, pre-fix write-pointer mutation caught)"
