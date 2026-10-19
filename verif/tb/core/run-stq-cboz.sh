#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# store_unit + store_buffer cbo.zero leaf (T44): a committed cbo.zero drains CBO_BLOCK_BYTES/8 zero beats
# over the whole 64-byte block. Positive, +oracle_negative (must fail), and the G6LC_MUT_CBOZ_LINE_BYTES
# mutation (block derived from DCACHE_LINE_WIDTH / 8 = 16 bytes: must fail STQ_CBOZ_BLOCK_COVERED).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
OUT="${STQ_CBOZ_OUT:-/tmp/g6lc-stq-cboz}"
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
  "$ROOT/verif/tb/core/tb_g6lc_stq_cboz.sv"
)
build() {
  verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -I"$ROOT/core/include" -I"$ROOT/core/ooo" \
    "${SRCS[@]}" --top-module tb_g6lc_stq_cboz -Mdir "$OUT/$1" -o tb ${2:-} > "$OUT/$1.build.log" 2>&1
}
build pos
"$OUT/pos/tb" | tee "$OUT/pos.log" | grep -q "^PASS tb_g6lc_stq_cboz" || { echo "FAIL positive"; tail -3 "$OUT/pos.log"; exit 1; }
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
grep -q "STQ_\|ORACLE_NEGATIVE" "$OUT/neg.log" || { echo "FAIL oracle negative did not fire"; exit 1; }
build mut "+define+G6LC_MUT_CBOZ_LINE_BYTES"
"$OUT/mut/tb" > "$OUT/mut.log" 2>&1
grep -q "STQ_CBOZ_BEATS\|STQ_CBOZ_BLOCK_COVERED" "$OUT/mut.log" || { echo "FAIL mutation G6LC_MUT_CBOZ_LINE_BYTES not caught"; cat "$OUT/mut.log"; exit 1; }
set -e
echo "PASS run-stq-cboz (positive, oracle negative, line-bytes mutation caught)"
