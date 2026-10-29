#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
# r91: hyp g6lc_ai_exec enq-ready and exec-dot leaves at Dot4Stages=1/2.
set -uo pipefail
ROOT="$(pwd)"
export PATH="/usr/bin:/bin:$PATH"
CV="$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/cvxif_g6lc_ai"
OUT="/tmp/hyp8-ai-r91"
mkdir -p "$OUT"
build_run() {
  local top=$1 tag=$2; shift 2
  /usr/bin/verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND --unroll-count 4096 --unroll-stmts 200000 -j 2 \
    -I"$ROOT/core/include" -I"$CV/include" \
    "$ROOT/core/include/config_pkg.sv" "$CV/include/g6lc_ai_instr_pkg.sv" \
    "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
    "$CV/g6lc_ai_acc_bank.sv" "$CV/g6lc_ai_exec.sv" \
    "$ROOT/verif/tb/ai_island/$top.sv" --top-module $top -Mdir "$OUT/$tag" "$@" -o $tag 2>&1 | grep -E "%Error" | head -5
  if [[ -x "$OUT/$tag/$tag" ]]; then "$OUT/$tag/$tag" 2>&1 | grep -E "PASS|FAIL|%Error|assert|error" | head -8; else echo "BUILD-FAILED $tag"; fi
}
build_run tb_g6lc_ai_enq_ready enq_ready
build_run tb_g6lc_ai_exec_dot exec_dot_d1
build_run tb_g6lc_ai_exec_dot exec_dot_d2 -GD4S=2
