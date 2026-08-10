#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Standalone Verilator smoke for Xg6lcai P3 island spine
# (capability window + AI-3 addr check + descriptor engine).
#
# Usage:
#   bash verif/regress/ai-island-veri.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ -d /root/tools/verilator-v5.008/bin ]]; then
  export PATH="/root/tools/verilator-v5.008/bin:${PATH}"
  export VERILATOR_ROOT="${VERILATOR_ROOT:-/root/tools/verilator-v5.008/share/verilator}"
fi

log() { echo "[ai-island-veri] $*"; }
command -v verilator >/dev/null || { log "need verilator"; exit 1; }
command -v g++ >/dev/null || { log "need g++"; exit 1; }

OUT="${AI_ISLAND_OUT:-work-ver-ai-island}"
rm -rf "$OUT"
mkdir -p "$OUT"

log "verilate → $OUT (verilator $(verilator --version 2>/dev/null | head -1))"
verilator --no-timing -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSED -Wno-UNOPTFLAT \
  -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-BLKANDNBLK \
  --cc --exe --build -j 0 \
  -Mdir "$OUT" \
  --top-module g6lc_ai_island_top \
  -CFLAGS "-std=c++17 -DVL_DEBUG" \
  -I"$ROOT/corev_apu/include" \
  -I"$ROOT/corev_apu/ai_island/include" \
  "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
  "$ROOT/corev_apu/ai_island/include/g6lc_ai_desc_pkg.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_addr_check.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_cap_window.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_desc_engine.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_cpl_fifo.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_island_top.sv" \
  "$ROOT/verif/tb/ai_island/sim_main.cpp"
# Note: g6lc_ai_desc_fetch.sv omitted — EnableDmaFetch=0 default; no instance.
# SoC path pulls fetch via Makefile flist + axi_pkg.

log "run"
set +e
"$OUT/Vg6lc_ai_island_top" | tee "$OUT/run.log"
rc=${PIPESTATUS[0]}
set -e
if grep -q '\*\*\* SUCCESS \*\*\*' "$OUT/run.log" && [[ "$rc" -eq 0 ]]; then
  log "PASS"
  exit 0
fi
log "FAIL rc=$rc"
tail -40 "$OUT/run.log" || true
exit 1
