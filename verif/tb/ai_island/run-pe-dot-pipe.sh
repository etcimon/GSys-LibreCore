#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# g6lc_ai_pe_dot_pipe vs the combinational g6lc_ai_pe_dot oracle:
# bit-identical sums, float-pipe-equal latency, back-to-back INT8/INT4.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_PE_DOT_PIPE_OUT:-/tmp/g6lc-ai-pe-dot-pipe}"
if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi
for lanes in ${LANES_LIST:-1 4 16 256}; do
  mdir="$OUT-l$lanes"
  mkdir -p "$mdir"
  verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -GLANES="$lanes" \
    -I"$ROOT/core/include" \
    "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot.sv" \
    "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot_pipe.sv" \
    "$ROOT/verif/tb/ai_island/tb_g6lc_ai_pe_dot_pipe.sv" \
    --top-module tb_g6lc_ai_pe_dot_pipe -Mdir "$mdir" -o tb_pe_dot_pipe > "$mdir/build.log" 2>&1 \
    || { tail -30 "$mdir/build.log"; exit 1; }
  "$mdir/tb_pe_dot_pipe" | tee "$mdir/sim.log"
  grep -q "PE_DOT_PIPE_PASS" "$mdir/sim.log"
done
echo "PASS tb_g6lc_ai_pe_dot_pipe lanes=${LANES_LIST:-1 4 16 256}"
