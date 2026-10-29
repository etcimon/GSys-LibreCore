#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
# WSL/Linux focused gates. Outputs and pinned references stay in workspace/.
set -euo pipefail
ulimit -c 0
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../../../.." && pwd)"
cd "$ROOT"
HC="$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4"
HA="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4"
AI="$HA/corev_apu/ai_island"
LOGS="$HERE/logs"
OUT="$ROOT/build-platform/workspace/build/r94-local"
mkdir -p "$OUT" "$LOGS"
V="${VERILATOR:-/usr/bin/verilator}"
FLAGS=(--assert -Wno-fatal -Wno-TIMESCALEMOD -Wno-WIDTHTRUNC
       -Wno-WIDTHEXPAND -Werror-LATCH -Werror-MULTIDRIVEN -j 2)
BASE=4b060f9c2
MODE="${1:-all}"
"$V" --version
pin() {
  git show "$BASE:$1" > "$2"
}
run() {
  local tag=$1 marker=$2
  shift 2
  "$@" > "$LOGS/sim-$tag.log" 2>&1 || {
    tail -35 "$LOGS/sim-$tag.log"; return 1;
  }
  if grep -qE '(^|[[:space:]])FAIL|%Error|SKIP' "$LOGS/sim-$tag.log"; then
    echo "FAIL unexpected diagnostic in $tag"; return 1
  fi
  grep -E "$marker" "$LOGS/sim-$tag.log"
}
build() {
  local tag=$1
  shift
  "$V" "${FLAGS[@]}" "$@" > "$LOGS/build-$tag.log" 2>&1 || {
    tail -50 "$LOGS/build-$tag.log"; return 1;
  }
}
clmul() {
  pin "${HC#"$ROOT/"}/core/mult_clmul.sv" "$OUT/mult_clmul_head.sv"
  local src tag
  for tag in clmul-cand clmul-head; do
    src="$HC/core/mult_clmul.sv"
    [[ "$tag" == clmul-head ]] && src="$OUT/mult_clmul_head.sv"
    build "$tag" --binary --timing -I"$HC/core/include" \
      "$HC/core/include/config_pkg.sv" "$HC/core/include/build_config_pkg.sv" \
      "$HC/core/include/g6lc_hyp_pkg.sv" "$HC/core/include/g6lc64_hyp8_config_pkg.sv" \
      "$HC/core/include/riscv_pkg.sv" "$HC/core/include/g6lc_core_pkg.sv" \
      "$src" "$ROOT/verif/tb/core/multiplier_sbs/tb_clmul_hyp8.sv" \
      --top-module tb_clmul_hyp8 -Mdir "$OUT/$tag" -o sim
    run "$tag" '^PASS tb_clmul_hyp8 checks=' "$OUT/$tag/sim"
  done
  if "$OUT/clmul-cand/sim" +negative_oracle > "$LOGS/clmul-negative.log" 2>&1; then
    echo "FAIL clmul negative control"; return 1
  fi
  grep -q '^FAIL polynomial' "$LOGS/clmul-negative.log"
  echo "PASS clmul negative control"
}
wtrk() {
  pin "${HA#"$ROOT/"}/corev_apu/l2_cache/g6lc_l2_wtrk.sv" "$OUT/wtrk_head.sv"
  local depth tag
  for depth in 1 3 4 8; do
    tag="wtrk-d$depth"
    build "$tag" --cc --exe --build -GDEPTH="$depth" -GADDR_WIDTH=16 \
      -CFLAGS "-DWTRK_DEPTH=$depth" "$HA/corev_apu/l2_cache/g6lc_l2_wtrk.sv" \
      "$ROOT/verif/tb/l2/wtrk_r94_main.cpp" --top-module g6lc_l2_wtrk \
      -Mdir "$OUT/$tag" -o sim
    run "$tag" '^PASS wtrk_r94 ' "$OUT/$tag/sim"
  done
  build wtrk-head --cc --exe --build -GDEPTH=4 -GADDR_WIDTH=16 \
    -CFLAGS "-DWTRK_DEPTH=4" "$OUT/wtrk_head.sv" "$ROOT/verif/tb/l2/wtrk_r94_main.cpp" \
    --top-module g6lc_l2_wtrk -Mdir "$OUT/wtrk-head" -o sim
  run wtrk-head '^PASS wtrk_r94 ' "$OUT/wtrk-head/sim"
}
floatpipe() {
  pin "${AI#"$ROOT/"}/g6lc_ai_pe_dot_float_pipe.sv" "$OUT/float_head.sv"
  sed 's/^module g6lc_ai_pe_dot_float_pipe #(/module g6lc_ai_pe_dot_float_pipe_ref #(/' \
    "$OUT/float_head.sv" > "$OUT/float_ref.sv"
  local lanes tag
  for lanes in 1 3 16 64; do
    tag="float-l$lanes"
    build "$tag" --cc --exe --build -GLanes="$lanes" \
      -CFLAGS "-DG6LC_HYP8_FLOAT_PIPE" \
      "$HC/core/include/config_pkg.sv" "$AI/include/g6lc_ai_fp_pkg.sv" \
      "$OUT/float_ref.sv" "$AI/g6lc_ai_pe_dot_float_pipe.sv" \
      "$ROOT/verif/tb/ai_island/tb_g6lc_ai_pe_dot_float_pipe_r94.sv" \
      "$ROOT/verif/tb/ai_island/pe_dot_float_pipe_main.cpp" \
      --top-module tb_g6lc_ai_pe_dot_float_pipe_r94 \
      --prefix Vg6lc_ai_pe_dot_float_pipe -Mdir "$OUT/$tag" -o sim
    run "$tag" '^PASS pe_dot_float_pipe ' "$OUT/$tag/sim"
  done
}
floatlint() {
  build float-l512-lint --lint-only -GLanes=512 \
    "$HC/core/include/config_pkg.sv" "$AI/include/g6lc_ai_fp_pkg.sv" \
    "$AI/g6lc_ai_pe_dot_float_pipe.sv" --top-module g6lc_ai_pe_dot_float_pipe
  echo "PASS floatpipe Lanes=512 elaboration/lint" | tee "$LOGS/float-l512-lint.status"
}
cache() {
  local lc="$HA/corev_apu/l2_cache"
  build cache --binary --timing -GTAG_SRAM=1 -GPOSTED_WRITES=1 -GWRITE_UPDATE=1 \
    "$ROOT/vendor/pulp-platform/axi/src/axi_pkg.sv" \
    "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
    "$lc/g6lc_l2_pkg.sv" "$lc/g6lc_l2_tag.sv" "$lc/g6lc_l2_data.sv" \
    "$lc/g6lc_l2_mshr.sv" "$lc/g6lc_l2_wtrk.sv" "$lc/g6lc_l2_pf.sv" \
    "$lc/g6lc_l2_top.sv" "$ROOT/verif/tb/l2/tb_g6lc_l2.sv" \
    --top-module tb_g6lc_l2 -Mdir "$OUT/cache" -o sim
  run cache '^\[L2TB\] RESULT pass$' "$OUT/cache/sim"
}
case "$MODE" in
  clmul|wtrk|floatpipe|floatlint|cache) "$MODE" ;;
  all) clmul; wtrk; floatpipe; floatlint; echo R94-LEAF-ALL-PASS ;;
  *) echo "Unknown mode: $MODE" >&2; exit 2 ;;
esac
