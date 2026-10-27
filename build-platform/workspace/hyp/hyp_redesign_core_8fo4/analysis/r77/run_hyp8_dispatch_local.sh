#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Local (WSL stock Verilator 5.020) dispatch leaf on the full hyp8 flist:
# the inner-loop gate for g6lc_iq / g6lc_ooo_dispatch edits (the remote
# pinned runtime via run_hyp8_memory.py HYP8_LEAF=dispatch stays the leaf
# of record).  Usage: run_hyp8_dispatch_local.sh [tag] [extra verilator args]
set -uo pipefail
ROOT=/mnt/e/cva6
HYP=$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4
TAG="${1:-plain}"; shift 2>/dev/null || true
OUT=/tmp/hyp8-disp-$TAG
mkdir -p "$OUT"
sed "s|\${HYP_CORE_DIR}|$HYP|g" "$HYP/core/Flist.g6lc_hyp8" > "$OUT/flist.f"
verilator --cc --main --exe --timing --assert --threads 1 -Wno-fatal -Werror-LATCH \
  -Wno-BLKANDNBLK "$@" -f "$OUT/flist.f" "$ROOT/verif/tb/core/tb_g6lc_hyp8_control.sv" \
  --top-module tb_g6lc_hyp8_dispatch --Mdir "$OUT/model" -o hyp8_dispatch \
  > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
make -s -C "$OUT/model" -f Vtb_g6lc_hyp8_dispatch.mk -j6 >> "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
"$OUT/model/hyp8_dispatch" | tee "$OUT/sim.log" | grep -E "HYP8_DISPATCH|equiv|Error|error|FAIL" | head -40
