#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# r127: equivalence of the rewritten aes.sv forms, then the negative control
# (-DG6LC_MUT_AES_EQ must print ..._FAIL).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HYP="${AES_EQ_HYP_CORE:-$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core}"
OUT="${AES_EQ_OUT:-$ROOT/build-platform/workspace/build/hyp8-aes-eq}"
rc=0
for v in plain mut; do
  D=""; [ "$v" = mut ] && D=-DG6LC_MUT_AES_EQ
  mkdir -p "$OUT/$v"
  if ! "${VERILATOR:-verilator}" --binary --timing -Wno-fatal $D --Mdir "$OUT/$v/model" --top-module tb_g6lc_hyp8_aes_eq "$HYP/include/aes_pkg.sv" "$ROOT/verif/tb/core/tb_g6lc_hyp8_aes_eq.sv" > "$OUT/$v/build.log" 2>&1; then
    echo "[$v] BUILD FAIL $(grep -m2 '%Error' "$OUT/$v/build.log" | cut -c1-180)"; rc=1; continue
  fi
  line="$("$OUT/$v/model/Vtb_g6lc_hyp8_aes_eq" | grep -E 'HYP8_AES_EQ' | head -1)"
  echo "[$v] $line"
  if [ "$v" = plain ]; then echo "$line" | grep -q _PASS || rc=1; else echo "$line" | grep -q _FAIL || rc=1; fi
done
exit $rc
