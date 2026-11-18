#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# g6lc_iq ACCEL (Ara/RVV) head rule leaf.
set -euo pipefail
if [ -f /opt/testharness/env.sh ]; then
  # Prefer the tools/verilator g6lc PGO compiler when present.
  # shellcheck disable=SC1091
  . /opt/testharness/env.sh
  for cand in \
      /opt/testharness/toolchains/verilator-v5.008-g6lc-6fa24f6f-pgo \
      /opt/testharness/toolchains/verilator-v5.008-g6lc; do
    if [ -x "$cand/bin/verilator" ]; then
      export VLT_HOME="$cand"
      if [ -d "$cand/runtime" ]; then
        export VERILATOR_ROOT="$cand/runtime"
      elif [ -d "$cand/share/verilator" ]; then
        export VERILATOR_ROOT="$cand/share/verilator"
      fi
      export PATH="$cand/bin:$PATH"
      break
    fi
  done
fi
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
echo "verilator=$(command -v verilator) VERILATOR_ROOT=${VERILATOR_ROOT:-}"
OUT="${IQ_ACCEL_HEAD_OUT:-/tmp/g6lc-iq-accel-head}"
mkdir -p "$OUT"
SRCS=(
  "$ROOT/core/include/config_pkg.sv"
  "$ROOT/core/include/g6lc64_smt2_config_pkg.sv"
  "$ROOT/core/include/riscv_pkg.sv"
  "$ROOT/core/include/ariane_pkg.sv"
  "$ROOT/core/ooo/g6lc_ooo_pkg.sv"
  "$ROOT/core/ooo/g6lc_iq.sv"
  "$ROOT/verif/tb/core/tb_g6lc_iq_accel_head.sv"
)
build() {
  verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
    -I"$ROOT/core/include" -I"$ROOT/core/ooo" -I"$ROOT/core/include/fetch_B" \
    "${SRCS[@]}" --top-module tb_g6lc_iq_accel_head -Mdir "$OUT/$1" -o tb ${2:-} > "$OUT/$1.build.log" 2>&1
}
build pos
"$OUT/pos/tb" | tee "$OUT/pos.log" | grep -q "^PASS tb_g6lc_iq_accel_head" || { echo "FAIL positive"; cat "$OUT/pos/tb" 2>/dev/null; exit 1; }
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
grep -q "IQ_ACCEL_HEAD\|ORACLE_NEGATIVE" "$OUT/neg.log" || { echo "FAIL oracle negative did not fire"; exit 1; }
build mut "+define+G6LC_MUT_ACCEL_NOHEAD"
"$OUT/mut/tb" > "$OUT/mut.log" 2>&1
grep -q "IQ_ACCEL_HEAD" "$OUT/mut.log" || { echo "FAIL mutation G6LC_MUT_ACCEL_NOHEAD not caught"; exit 1; }
set -e
echo "PASS run-iq-accel-head (positive, oracle negative, no-head mutation caught)"
