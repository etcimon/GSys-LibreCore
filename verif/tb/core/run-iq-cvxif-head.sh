#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# g6lc_iq CVXIF head rule leaf: positive, +oracle_negative (must fail), and the
# G6LC_MUT_CVXIF_NOHEAD mutation (rule dropped: must fail IQ_CVXIF_HEAD).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
OUT="${IQ_CVXIF_HEAD_OUT:-/tmp/g6lc-iq-cvxif-head}"
mkdir -p "$OUT"
# The IQ elaborates against the g6lc64_smt2 package's cva6_config_pkg (the
# review harness's choice); the leaf overrides the fields it needs in-module.
SRCS=(
  "$ROOT/core/include/config_pkg.sv"
  "$ROOT/core/include/g6lc64_smt2_config_pkg.sv"
  "$ROOT/core/include/riscv_pkg.sv"
  "$ROOT/core/include/ariane_pkg.sv"
  "$ROOT/core/ooo/g6lc_ooo_pkg.sv"
  "$ROOT/core/ooo/g6lc_iq.sv"
  "$ROOT/verif/tb/core/tb_g6lc_iq_cvxif_head.sv"
)
build() {
  verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
    -I"$ROOT/core/include" -I"$ROOT/core/ooo" -I"$ROOT/core/include/fetch_B" \
    "${SRCS[@]}" --top-module tb_g6lc_iq_cvxif_head -Mdir "$OUT/$1" -o tb ${2:-} > "$OUT/$1.build.log" 2>&1
}
build pos
"$OUT/pos/tb" | tee "$OUT/pos.log" | grep -q "^PASS tb_g6lc_iq_cvxif_head" || { echo "FAIL positive"; exit 1; }
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
grep -q "IQ_CVXIF_HEAD\|ORACLE_NEGATIVE" "$OUT/neg.log" || { echo "FAIL oracle negative did not fire"; exit 1; }
build mut "+define+G6LC_MUT_CVXIF_NOHEAD"
"$OUT/mut/tb" > "$OUT/mut.log" 2>&1
grep -q "IQ_CVXIF_HEAD" "$OUT/mut.log" || { echo "FAIL mutation G6LC_MUT_CVXIF_NOHEAD not caught"; exit 1; }
set -e
echo "PASS run-iq-cvxif-head (positive, oracle negative, no-head mutation caught)"
