#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# g6lc_axi_atomics_wrap leaf (g6lc_axi_lrsc read-slot accounting across R-producing atomics): positive,
# +oracle_negative (must fail LRSC_ATOP_S2_SWAP_DATA) and the G6LC_MUT_LRSC_ATOP_R_UNCOUNTED mutation (the
# pre-fix accounting: the AMO adapter's injected R pops a read that was never counted -- must fail
# g6lc_axi_lrsc_r_owed, and LRSC_ATOP_S1_AR_REFUSED with assertions off).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
OUT="${LRSC_ATOP_OUT:-/tmp/g6lc-axi-lrsc-atop}"
V="$ROOT/vendor/pulp-platform"
mkdir -p "$OUT"
SRCS=(
  "$V/axi/src/axi_pkg.sv"
  "$V/axi/src/axi_intf.sv"
  "$V/common_cells/src/spill_register_flushable.sv"
  "$V/common_cells/src/spill_register.sv"
  "$V/axi/src/axi_cut.sv"
  "$V/axi_riscv_atomics/src/axi_riscv_amos_alu.sv"
  "$V/axi_riscv_atomics/src/axi_riscv_amos.sv"
  "$ROOT/corev_apu/src/g6lc_axi_lrsc.sv"
  "$ROOT/corev_apu/src/g6lc_axi_atomics_wrap.sv"
  "$ROOT/verif/tb/uncore/tb_g6lc_axi_lrsc_atop.sv"
)
build() {
  verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-DECLFILENAME \
    -I"$V/axi/include" -I"$V/common_cells/include" \
    "${SRCS[@]}" --top-module tb_g6lc_axi_lrsc_atop -Mdir "$OUT/$1" -o tb ${2:-} > "$OUT/$1.build.log" 2>&1
}
build pos
"$OUT/pos/tb" | tee "$OUT/pos.log" | grep -q "^PASS tb_g6lc_axi_lrsc_atop" || { echo "FAIL positive"; tail -3 "$OUT/pos.log"; exit 1; }
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
grep -q "LRSC_ATOP_S2_SWAP_DATA" "$OUT/neg.log" || { echo "FAIL oracle negative did not fire"; exit 1; }
build mut "+define+G6LC_MUT_LRSC_ATOP_R_UNCOUNTED"
"$OUT/mut/tb" > "$OUT/mut.log" 2>&1
grep -q "g6lc_axi_lrsc_r_owed" "$OUT/mut.log" || { echo "FAIL mutation not caught by the RTL assertion"; tail -5 "$OUT/mut.log"; exit 1; }
# Assertions off: the mutation must still show the functional symptom, a refused AR on an idle bus.
"$OUT/mut/tb" +verilator+noassert > "$OUT/mut-noassert.log" 2>&1
grep -q "LRSC_ATOP_S1_AR_REFUSED" "$OUT/mut-noassert.log" || { echo "FAIL mutation G6LC_MUT_LRSC_ATOP_R_UNCOUNTED: AR not refused"; tail -5 "$OUT/mut-noassert.log"; exit 1; }
set -e
echo "PASS run-axi-lrsc-atop (positive, oracle negative, uncounted-atomic mutation caught)"
