#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
# r93: hyp g6lc_ai_exec dot leaf across D4S{1,2} x NREG{2,3,4} + one
# XLEN=32 config. Builds abort on any failure; sims must print PASS.
set -euo pipefail
ROOT="$(pwd)"
export PATH="/usr/bin:/bin:$PATH"
CV="$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/cvxif_g6lc_ai"
R93="$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/analysis/r93"
OUT="$ROOT/build-platform/workspace/build/hyp8-ai-r92"
mkdir -p "$OUT" "$R93/logs"
: > "$R93/logs/summary.txt"
SRC=(
  "$ROOT/core/include/config_pkg.sv" "$CV/include/g6lc_ai_instr_pkg.sv"
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv"
  "$CV/g6lc_ai_acc_bank.sv" "$CV/g6lc_ai_exec.sv"
)
run_cfg() {
  local tag=$1; shift
  local mdir="$OUT/$tag"
  /usr/bin/verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD \
    -Wno-UNUSED -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    --unroll-count 4096 --unroll-stmts 200000 -j 2 \
    -I"$ROOT/core/include" -I"$CV/include" \
    "${SRC[@]}" "$ROOT/verif/tb/ai_island/tb_g6lc_ai_exec_dot.sv" \
    --top-module tb_g6lc_ai_exec_dot -Mdir "$mdir" -o "$tag" "$@" \
    > "$R93/logs/build-$tag.log" 2>&1 \
    || { echo "BUILD-FAILED $tag" | tee -a "$R93/logs/summary.txt"; tail -20 "$R93/logs/build-$tag.log"; exit 1; }
  "$mdir/$tag" > "$R93/logs/sim-$tag.log" 2>&1 \
    || { echo "RUN-FAILED $tag ($*) rc=$?" | tee -a "$R93/logs/summary.txt"; tail -20 "$R93/logs/sim-$tag.log"; exit 1; }
  if grep -q '^FAIL' "$R93/logs/sim-$tag.log"; then
    echo "SIM-FAILED $tag ($*)" | tee -a "$R93/logs/summary.txt"; tail -20 "$R93/logs/sim-$tag.log"; exit 1;
  fi
  grep -q '^PASS tb_g6lc_ai_exec_dot checks=' "$R93/logs/sim-$tag.log" \
    || { echo "NO-PASS $tag ($*)" | tee -a "$R93/logs/summary.txt"; tail -20 "$R93/logs/sim-$tag.log"; exit 1; }
  echo "$tag ($*) $(grep '^PASS' "$R93/logs/sim-$tag.log")" | tee -a "$R93/logs/summary.txt"
}
run_cfg d1n2 -GD4S=1 -GNREG=2
run_cfg d1n3 -GD4S=1 -GNREG=3
run_cfg d1n4 -GD4S=1 -GNREG=4
run_cfg d2n2 -GD4S=2 -GNREG=2
run_cfg d2n3 -GD4S=2 -GNREG=3
run_cfg d2n4 -GD4S=2 -GNREG=4
run_cfg d2n3x32 -GD4S=2 -GNREG=3 -GXLEN=32
run_cfg d1n3x32 -GD4S=1 -GNREG=3 -GXLEN=32
echo "R93-LEAF-ALL-PASS" | tee -a "$R93/logs/summary.txt"
