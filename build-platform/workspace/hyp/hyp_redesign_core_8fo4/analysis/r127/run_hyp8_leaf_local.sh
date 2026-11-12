#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Local (WSL stock Verilator) full-flist hyp8 leaf: any tb_g6lc_hyp8_<leaf>
# top of verif/tb/core/tb_g6lc_hyp8_control.sv (dispatch, realign, queue,
# alu, dcache, lsq, mmu, ctrl, lbuf, linecheck, pmp, rom). The remote pinned
# runtime (run_hyp8_memory.py HYP8_LEAF=...) stays the leaf of record; this
# is the inner-loop gate. Same recipe as analysis/r77/run_hyp8_dispatch_local.sh.
#   bash analysis/r127/run_hyp8_leaf_local.sh <leaf> [tag] [extra verilator args]
#   LEAF_EXTRA_SRCS="a.sv b.sv" adds sources after the flist (csr leaf: core/neg/mut_*.sv)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYP="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$HYP/../../../.." && pwd)"
LEAF="${1:?usage: run_hyp8_leaf_local.sh <leaf> [tag] [verilator args]}"; shift
TAG="${1:-plain}"; shift 2>/dev/null || true
OUT="${LEAF_OUT:-$ROOT/build-platform/workspace/build/hyp8-leaf-r127}/$LEAF-$TAG"
mkdir -p "$OUT"
sed "s|\${HYP_CORE_DIR}|$HYP|g" "$HYP/core/Flist.g6lc_hyp8" > "$OUT/flist.f"
# LEAF_FLIST_SED: optional sed program applied to the materialized flist (file substitution for A/B runs)
[ -n "${LEAF_FLIST_SED:-}" ] && sed -i -e "$LEAF_FLIST_SED" "$OUT/flist.f"
verilator --cc --main --exe --timing --assert --threads 1 -Wno-fatal -Werror-LATCH   -Wno-BLKANDNBLK "$@" -f "$OUT/flist.f" ${LEAF_EXTRA_SRCS:-} "${LEAF_BENCH:-$ROOT/verif/tb/core/tb_g6lc_hyp8_control.sv}" "$ROOT/verif/tb/apu/g6lc_dram_peek64_stub.cpp"   --top-module "tb_g6lc_hyp8_$LEAF" --Mdir "$OUT/model" -o "hyp8_$LEAF"   > "$OUT/build.log" 2>&1 || { echo "LEAF $LEAF-$TAG: verilate failed"; grep -m6 '%Error' "$OUT/build.log"; exit 1; }
make -s -C "$OUT/model" -f "Vtb_g6lc_hyp8_$LEAF.mk" -j6 >> "$OUT/build.log" 2>&1   || { echo "LEAF $LEAF-$TAG: compile failed"; tail -8 "$OUT/build.log"; exit 1; }
"$OUT/model/hyp8_$LEAF" ${LEAF_PLUSARGS:-+equiv_report} > "$OUT/sim.log" 2>&1
RC=$?
echo "LEAF $LEAF-$TAG rc=$RC $(grep -cE '%Error|equiv [a-z]' "$OUT/sim.log") error-lines"
grep -E "HYP8_[A-Z0-9_]+_(PASS|FAIL)|\[equiv\]|%Error" "$OUT/sim.log" | head -${LEAF_LINES:-14}
exit $RC
