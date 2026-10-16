#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# lsu_bypass + store_unit leaf (T35 cancelled store, T40 exception double pop): positive, +oracle_negative
# (must fail), the G6LC_MUT_STQ_NO_STICKY_CANCEL mutation (mask consulted at push time only: must fail
# STQ_CANCELLED_NOT_PUSHED) and the G6LC_MUT_SU_EX_POP_ALWAYS mutation (unconditional exception pop:
# must fail STQ_EX_VALID_STORE_NO_DOUBLE_POP).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
OUT="${STQ_CANCEL_PTW_OUT:-/tmp/g6lc-stq-cancel-ptw}"
mkdir -p "$OUT"
SRCS=(
  "$ROOT/core/include/config_pkg.sv"
  "$ROOT/core/include/g6lc64_ooo_config_pkg.sv"
  "$ROOT/core/include/riscv_pkg.sv"
  "$ROOT/core/include/ariane_pkg.sv"
  "$ROOT/core/ooo/g6lc_ooo_pkg.sv"
  "$ROOT/core/lsu_bypass.sv"
  "$ROOT/core/store_buffer.sv"
  "$ROOT/core/cva6_fifo_v3.sv"
  "$ROOT/core/amo_buffer.sv"
  "$ROOT/core/store_unit.sv"
  "$ROOT/verif/tb/core/tb_g6lc_stq_cancel_ptw.sv"
)
build() {
  verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -I"$ROOT/core/include" -I"$ROOT/core/ooo" \
    "${SRCS[@]}" --top-module tb_g6lc_stq_cancel_ptw -Mdir "$OUT/$1" -o tb ${2:-} > "$OUT/$1.build.log" 2>&1
}
build pos
"$OUT/pos/tb" | tee "$OUT/pos.log" | grep -q "^PASS tb_g6lc_stq_cancel_ptw" || { echo "FAIL positive"; tail -3 "$OUT/pos.log"; exit 1; }
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
grep -q "STQ_\|ORACLE_NEGATIVE" "$OUT/neg.log" || { echo "FAIL oracle negative did not fire"; exit 1; }
build mut "+define+G6LC_MUT_STQ_NO_STICKY_CANCEL"
"$OUT/mut/tb" > "$OUT/mut.log" 2>&1
grep -q "STQ_CANCELLED_NOT_PUSHED\|scoreboard slot is not live" "$OUT/mut.log" || { echo "FAIL mutation G6LC_MUT_STQ_NO_STICKY_CANCEL not caught"; cat "$OUT/mut.log"; exit 1; }
build mut2 "+define+G6LC_MUT_SU_EX_POP_ALWAYS"
"$OUT/mut2/tb" > "$OUT/mut2.log" 2>&1
grep -q "STQ_EX_VALID_STORE_NO_DOUBLE_POP" "$OUT/mut2.log" || { echo "FAIL mutation G6LC_MUT_SU_EX_POP_ALWAYS not caught"; cat "$OUT/mut2.log"; exit 1; }
set -e
echo "PASS run-stq-cancel-ptw (positive, oracle negative, no-sticky-cancel + exception-double-pop mutations caught)"
