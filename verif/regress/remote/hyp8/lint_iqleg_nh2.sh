#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Elaborate g6lc_iq_legal alone at NH=2 (the SMT2 per-hart frontier arm the
# NH=1 hyp8 full-core lint never instantiates).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
H="${HYP_CORE_DIR:-$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core}"
verilator --lint-only -Wno-fatal -Wno-UNUSED -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -DG6LC_FETCH_B \
  -I"$H/include" -I"$H/ooo" -GNH=2 -GHID_W=1 --top-module g6lc_iq_legal \
  "$H/include/config_pkg.sv" "$H/include/build_config_pkg.sv" "$H/include/g6lc_hyp_pkg.sv" \
  "$H/include/g6lc64_hyp8_config_pkg.sv" "$H/include/riscv_pkg.sv" "$H/include/g6lc_core_pkg.sv" \
  "$H/ooo/g6lc_ooo_pkg.sv" "$H/ooo/g6lc_iq_legal.sv" 2>&1 \
  | grep -E '%Error|%Warning-(LATCH|IMPLICIT|MULTIDRIVEN|WIDTH):' && exit 1
echo "g6lc_iq_legal NH=2: clean"
