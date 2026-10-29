#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Local hyp8_lsq leaf (tb_g6lc_hyp8_control.sv, top tb_g6lc_hyp8_lsq).
set -uo pipefail
ROOT=/mnt/e/cva6
HYP=$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4
TAG="${1:-plain}"; shift 2>/dev/null || true
OUT=/tmp/hyp8-lsq-$TAG
mkdir -p "$OUT"
sed "s|\${HYP_CORE_DIR}|$HYP|g" "$HYP/core/Flist.g6lc_hyp8" > "$OUT/flist.f"
verilator --cc --main --exe --timing --assert --threads 1 -Wno-fatal -Werror-LATCH \
  -Wno-BLKANDNBLK "$@" -f "$OUT/flist.f" "$ROOT/verif/tb/core/tb_g6lc_hyp8_control.sv" \
  --top-module tb_g6lc_hyp8_lsq --Mdir "$OUT/model" -o hyp8_lsq \
  > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
make -s -C "$OUT/model" -f Vtb_g6lc_hyp8_lsq.mk -j6 >> "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
"$OUT/model/hyp8_lsq" | tee "$OUT/sim.log" | grep -iE "pass|fail|error|equiv|done|fatal|LSQ" | head -40
