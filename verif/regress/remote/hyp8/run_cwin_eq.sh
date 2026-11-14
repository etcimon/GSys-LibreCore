#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Exhaustive equivalence of the stb_fwd commit-winner forms (r127).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
OUT="${OUT_DIR:-$ROOT/build-platform/workspace/build/hyp8-cwin-eq}"
mkdir -p "$OUT"
"${VERILATOR:-verilator}" --binary --timing -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  ${CWIN_DEFINES:-} --Mdir "$OUT/model" --top-module tb_g6lc_hyp8_cwin_eq \
  "$ROOT/verif/tb/core/tb_g6lc_hyp8_cwin_eq.sv" > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; exit 1; }
"$OUT/model/Vtb_g6lc_hyp8_cwin_eq" | grep -E "HYP8_CWIN_EQ|FAIL" | head -8
