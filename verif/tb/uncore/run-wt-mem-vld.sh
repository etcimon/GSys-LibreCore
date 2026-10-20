#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# wt_dcache_mem leaf (T43 valid-bit write single-requester, T46 byte-merged forward): positive, +oracle_negative
# (must fail), the G6LC_MUT_VLD_WDATA_INV_PRIO mutation (the pre-fix valid-bit data mux: an all-ways invalidation coinciding with a
# pending fixup inv_req validates the other ways with the missunit's tag -- must fail WT_MEM_VLD_S2_FOREIGN_VALID), the
# G6LC_MUT_WBUF_FWD_ONE_HOT mutation (S4) and the G6LC_MUT_RD_ACK_DURING_INV mutation (T48: a lookup acknowledged in a
# fixup inv_req cycle returns a false miss -- must fail WT_MEM_VLD_S5_FALSE_MISS).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
OUT="${WT_MEM_VLD_OUT:-/tmp/g6lc-wt-mem-vld}"
mkdir -p "$OUT"
SRCS=(
  "$ROOT/core/include/config_pkg.sv"
  "$ROOT/core/include/g6lc64_ooo_config_pkg.sv"
  "$ROOT/core/include/riscv_pkg.sv"
  "$ROOT/core/include/ariane_pkg.sv"
  "$ROOT/core/include/build_config_pkg.sv"
  "$ROOT/core/include/wt_cache_pkg.sv"
  "$ROOT/vendor/pulp-platform/common_cells/src/cf_math_pkg.sv"
  "$ROOT/vendor/pulp-platform/common_cells/src/lzc.sv"
  "$ROOT/vendor/pulp-platform/common_cells/src/rr_arb_tree.sv"
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv"
  "$ROOT/common/local/util/tc_sram_wrapper.sv"
  "$ROOT/common/local/util/tc_sram_wrapper_cache_techno.sv"
  "$ROOT/common/local/util/sram.sv"
  "$ROOT/common/local/util/sram_cache.sv"
  "$ROOT/core/cache_subsystem/wt_dcache_mem.sv"
  "$ROOT/verif/tb/uncore/tb_g6lc_wt_mem_vld.sv"
)
# the lzc flat signals are declared split, as run_cmo_review.py does for the wt_dcache leaf
cat > "$OUT/split.vlt" <<'VLT'
`verilator_config
split_var -module "lzc" -var "index_nodes"
split_var -module "lzc" -var "sel_nodes"
VLT
build() {
  verilator --binary "$OUT/split.vlt" --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-MULTIDRIVEN \
    -I"$ROOT/core/include" -I"$ROOT/core/cache_subsystem" \
    "${SRCS[@]}" --top-module tb_g6lc_wt_mem_vld -Mdir "$OUT/$1" -o tb ${2:-} > "$OUT/$1.build.log" 2>&1
}
build pos
"$OUT/pos/tb" | tee "$OUT/pos.log" | grep -q "^WT_MEM_VLD_PASS" || { echo "FAIL positive"; tail -5 "$OUT/pos.log"; exit 1; }
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
grep -q "WT_MEM_VLD_S2" "$OUT/neg.log" || { echo "FAIL oracle negative did not fire"; tail -3 "$OUT/neg.log"; exit 1; }
build mut "+define+G6LC_MUT_VLD_WDATA_INV_PRIO"
"$OUT/mut/tb" > "$OUT/mut.log" 2>&1
grep -q "WT_MEM_VLD_S2_FOREIGN_VALID\|missunit line write" "$OUT/mut.log" || { echo "FAIL mutation G6LC_MUT_VLD_WDATA_INV_PRIO not caught"; tail -5 "$OUT/mut.log"; exit 1; }
build mut2 "+define+G6LC_MUT_WBUF_FWD_ONE_HOT"
"$OUT/mut2/tb" > "$OUT/mut2.log" 2>&1
grep -q "WT_MEM_VLD_S4_PARTIAL_FORWARD" "$OUT/mut2.log" || { echo "FAIL mutation G6LC_MUT_WBUF_FWD_ONE_HOT not caught"; tail -5 "$OUT/mut2.log"; exit 1; }
build mut3 "+define+G6LC_MUT_RD_ACK_DURING_INV"
"$OUT/mut3/tb" > "$OUT/mut3.log" 2>&1
grep -q "WT_MEM_VLD_S5_FALSE_MISS" "$OUT/mut3.log" || { echo "FAIL mutation G6LC_MUT_RD_ACK_DURING_INV not caught"; tail -5 "$OUT/mut3.log"; exit 1; }
set -e
echo "PASS run-wt-mem-vld (positive, oracle negative, valid-bit mux + single-entry forward + read-ack-during-inv mutations caught)"
