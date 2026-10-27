#!/usr/bin/env bash
set -uo pipefail
ROOT=/mnt/e/cva6
HYP=$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core
TAG="${1:-plain}"; shift 2>/dev/null || true
OUT=/tmp/hyp8-mem-$TAG
mkdir -p "$OUT"
SRCS=(
  "$HYP/include/config_pkg.sv"
  "$HYP/include/build_config_pkg.sv"
  "$HYP/include/g6lc_hyp_pkg.sv"
  "$HYP/include/g6lc64_hyp8_config_pkg.sv"
  "$HYP/include/riscv_pkg.sv"
  "$HYP/include/g6lc_core_pkg.sv"
  "$HYP/ooo/g6lc_ooo_pkg.sv"
  "$HYP/ooo/g6lc_prf.sv"
  "$HYP/stb_insert.sv"
  "$HYP/stb_fwd.sv"
  "$HYP/store_buffer.sv"
  "$HYP/stb_commit.sv"
  "$HYP/stb_drain.sv"
  "/mnt/e/cva6/build-platform/workspace/hyp/hyp_redesign_core_8fo4/third_party/vendor/pulp-platform/common_cells/src/cf_math_pkg.sv"
  "$HYP/hyp_cells/g6lc_hyp_lzc.sv"
  "$HYP/load_unit.sv"
  "$ROOT/verif/tb/core/tb_g6lc_hyp8_memory.sv"
)
verilator --cc --main --exe --timing --assert --threads 1 -Wno-fatal -Werror-LATCH \
  -DG6LC_FETCH_B "$@" -I"$HYP/include" -I"$HYP/ooo" \
  --top-module tb_g6lc_hyp8_memory --Mdir "$OUT/model" -o hyp8_memory "${SRCS[@]}" \
  > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
if grep -E '%Warning-(WIDTH|IMPLICIT|MULTIDRIVEN|LATCH):|%Error' "$OUT/build.log"; then
  echo "hyp8-mem: fatal diagnostic class in build log"; exit 1
fi
make -s -C "$OUT/model" -f Vtb_g6lc_hyp8_memory.mk -j4 >> "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
"$OUT/model/hyp8_memory" | tee "$OUT/sim.log"
