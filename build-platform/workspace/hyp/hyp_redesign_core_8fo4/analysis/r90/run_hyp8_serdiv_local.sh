#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Local serdiv leaf on a minimal source set (cf run_hyp8_mem_local.sh).
set -uo pipefail
ROOT=/mnt/e/cva6
HYP=$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core
TAG="${1:-plain}"; shift 2>/dev/null || true
OUT=/tmp/hyp8-sd-$TAG
mkdir -p "$OUT"
SRCS=(
  "$HYP/include/config_pkg.sv"
  "$HYP/include/build_config_pkg.sv"
  "$HYP/include/g6lc_hyp_pkg.sv"
  "$HYP/include/g6lc64_hyp8_config_pkg.sv"
  "$HYP/include/riscv_pkg.sv"
  "$HYP/include/g6lc_core_pkg.sv"
  "$HYP/ooo/g6lc_ooo_pkg.sv"
  "/mnt/e/cva6/build-platform/workspace/hyp/hyp_redesign_core_8fo4/third_party/vendor/pulp-platform/common_cells/src/cf_math_pkg.sv"
  "$HYP/hyp_cells/g6lc_hyp_lzc.sv"
  "$HYP/serdiv.sv"
  "$ROOT/verif/tb/core/tb_g6lc_hyp8_serdiv.sv"
)
verilator --cc --main --exe --timing --assert --threads 1 -Wno-fatal -Werror-LATCH \
  "$@" -I"$HYP/include" -I"$HYP/ooo" \
  --top-module tb_g6lc_hyp8_serdiv --Mdir "$OUT/model" -o hyp8_serdiv "${SRCS[@]}" \
  > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
make -s -C "$OUT/model" -f Vtb_g6lc_hyp8_serdiv.mk -j4 >> "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
"$OUT/model/hyp8_serdiv" | tee "$OUT/sim.log" | grep -iE "SERDIV|PASS|FAIL|error" | head -20
