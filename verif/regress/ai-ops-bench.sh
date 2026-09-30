#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Quick AI-island GEMM bench: runs the reduced-geometry backend bench
# (tb_g6lc_ai_gemm_backend `measure` / `measure_k` cases) with the SAME runner and
# source-snapshot discipline as the remote review gate, but on the local host
# (Linux or WSL) with the managed Verilator 5.008, then reduces the MEASURE records
# to a per-format cycles-per-operation table (verif/regress/remote/ai_bench_report.py).
#
#   bash verif/regress/ai-ops-bench.sh                 # dpf=0 and dpf=1, measure + measure_k
#   AI_BENCH_DPF=0 AI_BENCH_CASES=measure bash verif/regress/ai-ops-bench.sh
#   AI_BENCH_OUT=/tmp/aibench bash verif/regress/ai-ops-bench.sh
#
# Evidence boundary: 8-lane reduced geometry against the simulated stripe, i.e.
# sequencer behaviour (phase split, MAC efficiency, load/store cost per beat), not
# live-512 throughput and not silicon timing. The report is what to tune against.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${AI_BENCH_OUT:-/tmp/ai-ops-bench}"
CASES="${AI_BENCH_CASES:-measure,measure_k,measure_reuse}"
# measure_reuse needs the reuse blocks elaborated; harmless for the other cases.
export REVIEW_AI_REUSE="${AI_BENCH_REUSE_EN:-1}"
# V2 column array: AI_BENCH_OUT_COLS=2/4 elaborates the sequencer with that many output columns.
export REVIEW_AI_OUT_COLS="${AI_BENCH_OUT_COLS:-}"
DPFS="${AI_BENCH_DPF:-0 1}"
VLT_ROOT="${AI_BENCH_VERILATOR_ROOT:-$HOME/tools/verilator-v5.008}"
[[ -x "$VLT_ROOT/bin/verilator" ]] || { echo "[ai-ops-bench] Verilator 5.008 not found at $VLT_ROOT (set AI_BENCH_VERILATOR_ROOT)"; exit 2; }
HDR_SHA=$(sha256sum "$VLT_ROOT/share/verilator/include/verilated_funcs.h" | cut -d' ' -f1)
[[ "$HDR_SHA" == "8c408609b477f5d29c0897bf5412c8417676f9ea66c6622809c1796b4ac3099e" ]] || {
  echo "[ai-ops-bench] verilated_funcs.h is not the pinned v5.008 header ($HDR_SHA); the CONSTHI repair would not apply"; exit 2; }
rm -rf "$OUT"; mkdir -p "$OUT/data"
python3 -B "$ROOT/verif/regress/remote/run_ai_spine_review.py" --prepare-dma "$OUT/data/snap.zip" --backend | tail -1
cat > "$OUT/data/runtime.json" <<EOF
{"originalRoot": "$VLT_ROOT/share/verilator", "privateRoot": "$OUT/private-runtime",
 "originalHeaderSha256": "$HDR_SHA",
 "fixedHeaderSha256": "dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166",
 "change": "CONSTHI zero-fill uses unshifted obase with absolute word indices; return pointer unchanged"}
EOF
status=0
for dpf in $DPFS; do
  run="$OUT/dpf$dpf"; mkdir -p "$run"
  echo "[ai-ops-bench] dpf=$dpf cases=$CASES -> $run"
  # The runner's exit code also carries the strict-lint verdict of the bench TB mux
  # (a known INCOMPLETE); the bench needs the functional pass, the detected negative
  # control and the MEASURE records, which results.json states explicitly.
  (cd "$OUT" && TH_DATA_DIR="$OUT/data" TH_OUT_DIR="$run" REVIEW_RUNTIME_JSON="$OUT/data/runtime.json" \
        REVIEW_RESTORE_RUNTIME=1 REVIEW_AI_BACKEND=1 REVIEW_AI_DIAGNOSTIC=1 REVIEW_AI_DOT_PIPE="$dpf" \
        REVIEW_AI_CASES="$CASES" PATH="$VLT_ROOT/bin:/usr/bin:/bin" \
        python3 -B "$ROOT/verif/regress/remote/run_ai_spine_review.py" > "$run/runner.log" 2>&1) || true
  if ! python3 - "$run/results.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
ok = r.get("functional_pass") is True and r.get("negative_detected") is True
print(f"[ai-ops-bench]   functional_pass={r.get('functional_pass')} negative_detected={r.get('negative_detected')} strict_lint_rc={r.get('strict_lint_rc')} (lint is the separate gate)")
sys.exit(0 if ok else 1)
PY
  then echo "[ai-ops-bench] bench FAILED for dpf=$dpf — $run/runner.log"; tail -5 "$run/runner.log"; status=1; fi
  for c in ${CASES//,/ }; do
    case "$c" in measure*) ;; *) continue ;; esac   # directed cases carry PASS markers, not MEASURE records
    n=$(grep -c '^MEASURE fmt' "$run/simulation-$c.log" 2>/dev/null || echo 0)
    [[ "$n" -gt 0 ]] || { echo "[ai-ops-bench] no MEASURE records for case $c (dpf=$dpf)"; status=1; }
  done
  # REVIEW_RESTORE_RUNTIME builds the private runtime once; reuse it for the next dpf.
  [[ -d "$run/runtime" && ! -d "$OUT/private-runtime" ]] && cp -r "$run/runtime" "$OUT/private-runtime"
done
python3 -B "$ROOT/verif/regress/remote/ai_bench_report.py" "$OUT" --json "$OUT/ai-ops-bench.json" | tee "$OUT/ai-ops-bench.txt"
[[ $status == 0 ]] && echo "[ai-ops-bench] PASS — $OUT/ai-ops-bench.json" || echo "[ai-ops-bench] FAIL"
exit $status
