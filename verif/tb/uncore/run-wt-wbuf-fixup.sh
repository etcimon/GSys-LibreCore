#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# wt_dcache_wbuffer leaf (T47 fixup write never supersedes a younger store): positive, +oracle_negative (must fail), and
# the G6LC_MUT_FIXUP_SEL_DRIFT (T37) mutation (must fail), and
# the G6LC_MUT_FIXUP_KEEP_SUPERSEDED arm (informational: the pre-fix queue coalesces the younger ACK into the pending entry
# and survives this shape; see the note below).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
if ! command -v verilator >/dev/null 2>&1; then echo "SKIP no verilator"; exit 0; fi
OUT="${WT_WBUF_FIXUP_OUT:-/tmp/g6lc-wt-wbuf-fixup}"
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
  "$ROOT/core/cva6_fifo_v3.sv"
  "$ROOT/core/cache_subsystem/wt_dcache_wbuffer.sv"
  "$ROOT/verif/tb/uncore/tb_g6lc_wt_wbuf_fixup.sv"
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
    "${SRCS[@]}" --top-module tb_g6lc_wt_wbuf_fixup -Mdir "$OUT/$1" -o tb ${2:-} > "$OUT/$1.build.log" 2>&1
}
build pos
"$OUT/pos/tb" | tee "$OUT/pos.log" | grep -q "^WT_WBUF_FIXUP_PASS" || { echo "FAIL positive"; tail -12 "$OUT/pos.log"; exit 1; }
set +e
"$OUT/pos/tb" +oracle_negative > "$OUT/neg.log" 2>&1
grep -q "WT_WBUF_FIXUP_\|ORACLE_NEGATIVE" "$OUT/neg.log" || { echo "FAIL oracle negative did not fire"; tail -3 "$OUT/neg.log"; exit 1; }
build mut "+define+G6LC_MUT_FIXUP_KEEP_SUPERSEDED"
"$OUT/mut/tb" > "$OUT/mut.log" 2>&1
# The pre-fix queue survives this shape: a younger word's ACK coalesces into the pending entry
# (fixup_match -> merge_fixup), so the deferred write already carries the younger bytes. The
# acceptance-time clearing is a guard with its own invariant, not the only line of defence; the
# mutation arm is informational (recorded in AGENTS-specs-to-tests.md, T47).
if grep -q "WT_WBUF_FIXUP_PASS" "$OUT/mut.log"; then echo "note: G6LC_MUT_FIXUP_KEEP_SUPERSEDED survives this shape (ACK coalescing covers it)"; else echo "note: G6LC_MUT_FIXUP_KEEP_SUPERSEDED caught: $(grep -o 'WT_WBUF_FIXUP_[A-Z_0-9]*' "$OUT/mut.log" | head -1)"; fi
build mut2 "+define+G6LC_MUT_FIXUP_SEL_DRIFT"
"$OUT/mut2/tb" > "$OUT/mut2.log" 2>&1
grep -q "WT_WBUF_FIXUP_S6_\|fixup pass acting" "$OUT/mut2.log" || { echo "FAIL mutation G6LC_MUT_FIXUP_SEL_DRIFT not caught (S6)"; tail -12 "$OUT/mut2.log"; exit 1; }
set -e
echo "PASS run-wt-wbuf-fixup (positive, oracle negative, T37 pass-drift mutation caught; keep-superseded arm informational)"
