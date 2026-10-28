#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
# r27: hyp g6lc_ai_exec through the enq-ready and exec-dot leaves (WSL).
set -uo pipefail
ROOT="$(pwd)"
export PATH="/usr/bin:/bin:$PATH"
CV="$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/cvxif_g6lc_ai"
OUT="$ROOT/build-platform/workspace/build/ai-gemm/r27-exec"
mkdir -p "$OUT"
for top in tb_g6lc_ai_enq_ready tb_g6lc_ai_exec_dot; do
  /usr/bin/verilator --binary --timing --assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND --unroll-count 4096 --unroll-stmts 200000 -j 2 \
    -I"$ROOT/core/include" -I"$CV/include" \
    "$ROOT/core/include/config_pkg.sv" "$CV/include/g6lc_ai_instr_pkg.sv" \
    "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
    "$CV/g6lc_ai_acc_bank.sv" "$CV/g6lc_ai_exec.sv" \
    "$ROOT/verif/tb/ai_island/$top.sv" --top-module $top -Mdir "$OUT/$top" -o $top 2>&1 | grep -E "%Error" | head -5
  if [[ -x "$OUT/$top/$top" ]]; then "$OUT/$top/$top" 2>&1 | grep -E "PASS|FAIL|%Error" | head -5; else echo "BUILD-FAILED $top"; fi
done
