#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# AI island scaling ladder (architecture/ai-matrix/scaling-100tops.md; WP3 of the AI
# scaling plan) -- the local, minutes-long evidence for the four SKU steps:
#   1. SKU literals: legality, derived columns and the s2 nameplates (tb_g6lc_ai_scale_ladder).
#   2. Bounded formal over the flat-panel / stripe / slot arithmetic (sby, three geometries).
#   3. V2 column array on the 8-lane backend bench: OutCols 1 (identity), 2 and 4 -- every
#      directed case must PASS on both float pipes; the OutCols=1 measure sweep must be
#      cycle-identical to AI_LADDER_BASELINE when one is given.
#   4. The derived ladder table (ai_bench_report.py --sku), labelled derived.
# Full-geometry synthesis and the SoC points (V1 wide channel, bench SKU) are remote gates
# recorded in the AI log; this suite never claims them.
#
#   bash verif/regress/ai-scale-ladder.sh
#   AI_LADDER_BASELINE=/tmp/ai-ops-bench/ai-ops-bench.json bash verif/regress/ai-scale-ladder.sh
set -u
ROOT="${CVA6_REPO_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT="${AI_LADDER_OUT:-/tmp/ai-scale-ladder}"
COLS="${AI_LADDER_COLS:-1 2 4}"
BASE="${AI_LADDER_BASELINE:-}"
mkdir -p "$OUT"
log() { echo "[ai-scale-ladder] $*"; }
FAIL=0

# 1. SKU literals
VLT="${AI_BENCH_VERILATOR_ROOT:-$HOME/tools/verilator-v5.008}/bin/verilator"
[[ -x "$VLT" ]] || VLT="$(command -v verilator || true)"
if [[ -n "$VLT" ]]; then
  rm -rf "$OUT/ladder-tb"
  if "$VLT" --binary -Wno-fatal -Wno-WIDTH --Mdir "$OUT/ladder-tb" --top-module tb_g6lc_ai_scale_ladder \
       "$ROOT/core/include/config_pkg.sv" "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
       "$ROOT/verif/tb/ai_island/tb_g6lc_ai_scale_ladder.sv" > "$OUT/ladder-tb.log" 2>&1 \
     && "$OUT/ladder-tb/Vtb_g6lc_ai_scale_ladder" 2>&1 | tee -a "$OUT/ladder-tb.log" | grep -q "^PASS tb_g6lc_ai_scale_ladder"; then
    log "PASS sku-literals"; grep "^LADDER" "$OUT/ladder-tb.log" | sed 's/^/[ai-scale-ladder]   /'
  else log "FAIL sku-literals (see $OUT/ladder-tb.log)"; FAIL=1; fi
else log "SKIP sku-literals (no verilator)"; fi

# 2. Bounded formal
if command -v sby > /dev/null; then
  ( cd "$ROOT/corev_apu/ai_island/formal" && rm -rf g6lc_ai_gemm_flat_bench g6lc_ai_gemm_flat_live g6lc_ai_gemm_flat_live4ch \
    && sby -f g6lc_ai_gemm_flat.sby > "$OUT/sby.log" 2>&1 )
  if [[ "$(grep -c 'DONE (PASS' "$OUT/sby.log")" == 3 ]]; then log "PASS formal flat/stripe/slots (3 tasks)"
  else log "FAIL formal (see $OUT/sby.log)"; FAIL=1; fi
else log "SKIP formal (no sby)"; fi

# 3. V2 column array on the backend bench
for C in $COLS; do
  AI_BENCH_OUT_COLS="$C" AI_BENCH_DPF="${AI_LADDER_DPF:-0 1}" \
  AI_BENCH_CASES="${AI_LADDER_CASES:-measure,measure_reuse,review_signed,review_accumulate,review_flat,review_slots}" \
  AI_BENCH_OUT="$OUT/cols$C" bash "$ROOT/verif/regress/ai-ops-bench.sh" > "$OUT/cols$C.log" 2>&1
  if grep -q "ai-ops-bench\] PASS" "$OUT/cols$C.log"; then log "PASS backend bench OutCols=$C"
  else log "FAIL backend bench OutCols=$C (see $OUT/cols$C.log)"; FAIL=1; fi
  if [[ "$C" == 1 && -n "$BASE" && -f "$OUT/cols1/ai-ops-bench.json" ]]; then
    python3 - "$BASE" "$OUT/cols1/ai-ops-bench.json" <<'PY' || FAIL=1
import json, sys
key = lambda r: (r["fmt"], r["m"], r["n"], r["k"], r["ar"], r["dpf"], str(r.get("reuse", "-")), r.get("acc", 0))
a = {key(r): r["cycles"] for r in json.load(open(sys.argv[1]))["records"]}
b = {key(r): r["cycles"] for r in json.load(open(sys.argv[2]))["records"]}
common = [k for k in a if k in b]; diffs = [k for k in common if a[k] != b[k]]
print(f"[ai-scale-ladder] {'PASS' if not diffs else 'FAIL'} OutCols=1 identity: {len(common)} records, {len(diffs)} differ")
sys.exit(1 if diffs else 0)
PY
  fi
done

# 4. Derived ladder
python3 "$ROOT/verif/regress/remote/ai_bench_report.py" --sku | sed 's/^/[ai-scale-ladder] /'

if [[ "$FAIL" == 0 ]]; then log "PASS"; exit 0; else log "FAIL"; exit 1; fi
