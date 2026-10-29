#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Local (WSL stock Verilator 5.020) rtl-review leaf on the hyp8 flist.
# The source review file does not parse under 5.020 (fp_lifetime task
# syntax), so the target module is extracted to a temp file first; the
# extracted `function automatic config_pkg::cva6_cfg_t` return type is
# unqualified (`import config_pkg::*`) for the V3ParseSym bug.
# Usage: run_hyp8_review_local.sh <top> [tag] [extra verilator args]
set -uo pipefail
ROOT=/mnt/e/cva6
HYP=$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4
TOP="${1:?top}"; shift
TAG="${1:-plain}"; shift 2>/dev/null || true
OUT=/tmp/hyp8-rev-$TOP-$TAG
mkdir -p "$OUT"
SRC="$ROOT/verif/tb/core/tb_g6lc_rtl_review.sv"
awk -v m="$TOP" 'BEGIN{on=0} $0 ~ ("^module " m ";") {on=1} on{print} on && /^endmodule/{exit}' "$SRC" > "$OUT/rev.sv"
[ -s "$OUT/rev.sv" ] || { echo "extract failed for $TOP"; exit 1; }
# V3ParseSym workaround: qualified function return types lose the
# function scope on an extracted file — import + unqualify.
if grep -q "config_pkg::cva6_cfg_t" "$OUT/rev.sv"; then
  sed -i 's|function automatic config_pkg::cva6_cfg_t|function automatic cva6_cfg_t|; s|module '"$TOP"';|module '"$TOP"';\n  import config_pkg::*;|' "$OUT/rev.sv"
fi
sed "s|\${HYP_CORE_DIR}|$HYP|g" "$HYP/core/Flist.g6lc_hyp8" > "$OUT/flist.f"
verilator --cc --main --exe --timing --assert --threads 1 -Wno-fatal -Werror-LATCH \
  -Wno-BLKANDNBLK "$@" -f "$OUT/flist.f" "$OUT/rev.sv" \
  --top-module "$TOP" --Mdir "$OUT/model" -o "rev_$TOP" \
  > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
make -s -C "$OUT/model" -f "V${TOP}.mk" -j6 >> "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
"$OUT/model/rev_$TOP" | tee "$OUT/sim.log" | grep -iE "pass|fail|error|equiv|done|fatal|RENAME|CKPT|LSQ" | head -30
