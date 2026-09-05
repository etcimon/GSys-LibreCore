#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Unit-test g6lc_ai_pe_dot_float_pipe (pipelined FP8/FP16/BF16/FP32 dot) with
# Verilator. Default Lanes=8; set PE_DOT_FLOAT_PIPE_LANES to override.
# Intended to run under WSL or a Linux host where Verilator 5.x is available.
#
#   wsl -e bash /mnt/e/cva6/verif/tb/ai_island/run-pe-dot-float-pipe.sh
#
# Not Variane. Not a throughput number.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${PE_DOT_FLOAT_PIPE_OUT:-/tmp/g6lc-ai-pe-dot-float-pipe}"
LANES="${PE_DOT_FLOAT_PIPE_LANES:-8}"
mkdir -p "$OUT"

VERILATOR="${VERILATOR:-$ROOT/build-platform/workspace/tooling/verilator-v5.008-wsl/bin/verilator}"
if ! "$VERILATOR" --version >/dev/null 2>&1; then
  VERILATOR="verilator"
fi
if ! "$VERILATOR" --version >/dev/null 2>&1; then
  echo "SKIP no working verilator in PATH or build-platform workspace"
  exit 0
fi

"$VERILATOR" --cc --exe --build -j 2 \
  -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
  -I"$ROOT/core/include" -I"$ROOT/corev_apu/include" \
  -GLanes="$LANES" \
  "$ROOT/core/include/config_pkg.sv" \
  "$ROOT/corev_apu/ai_island/include/g6lc_ai_fp_pkg.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot_float_pipe.sv" \
  "$ROOT/verif/tb/ai_island/pe_dot_float_pipe_main.cpp" \
  --top-module g6lc_ai_pe_dot_float_pipe \
  -Mdir "$OUT" -o pe_dot_float_pipe >"$OUT/build.log" 2>&1 || {
  echo "FAIL build"; tail -50 "$OUT/build.log"; exit 1;
}

"$OUT/pe_dot_float_pipe"
