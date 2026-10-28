#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
# Focused existing benches against an immutable copy of the hyp AI RTL.
set -euo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "$0")/../../../../../.." && pwd)"
cd "$ROOT"
MODE="${1:?gate mode}"
TAG="${2:?unique evidence tag}"
OUT="$ROOT/build-platform/workspace/build/ai-gemm/$TAG"
test ! -e "$OUT"
mkdir -p "$OUT"
HYP="$ROOT/build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu"
cp -a "$HYP/ai_island" "$OUT/rtl"
find "$OUT/rtl" -type f -name '*.sv' -print0 | sort -z | xargs -0 sha256sum > "$OUT/source.sha256"
export PATH="/usr/bin:/bin:$PATH"
export VERILATOR=/usr/bin/verilator
export G6LC_AI_RTL_DIR="$OUT/rtl"
export G6LC_AI_INC_DIR="$HYP/include"
export G6LC_AI_SRC_DIR="$HYP/src"
export G6LC_AI_CVXIF_DIR="$ROOT/build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/cvxif_g6lc_ai"
export AI_ISLAND_DRAM_CHANNELS=1
/usr/bin/verilator --version
case "$MODE" in
  float)
    for lanes in 1 3; do
      PE_DOT_FLOAT_PIPE_LANES="$lanes" PE_DOT_FLOAT_PIPE_OUT="$OUT/l$lanes" \
        bash verif/tb/ai_island/run-pe-dot-float-pipe.sh
    done ;;
  intpipe)
    LANES_LIST='1 4' AI_PE_DOT_PIPE_OUT="$OUT/int" \
      bash verif/tb/ai_island/run-pe-dot-pipe.sh ;;
  int)
    PE_DOT_REQUIRE=1 PE_DOT_OUT="$OUT/int" bash verif/tb/ai_island/run-pe-dot.sh ;;
  intcpp)
    for suffix in '' _pipe; do
      cflags=()
      if [[ "$suffix" == _pipe ]]; then cflags=(-CFLAGS -DPE_DOT_PIPE); fi
      for lanes in 1 3 8; do
        top="g6lc_ai_pe_dot$suffix"
        mdir="$OUT/${top}-l$lanes"
        /usr/bin/verilator --cc --exe --build -j 2 --assert -Wno-fatal \
          -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -GLanes="$lanes" "${cflags[@]}" \
          "$G6LC_AI_RTL_DIR/$top.sv" "$ROOT/verif/tb/ai_island/pe_dot_int_main.cpp" \
          --top-module "$top" -Mdir "$mdir" -o dot_int
        "$mdir/dot_int"
      done
    done ;;
  floatcomb)
    /usr/bin/verilator --cc --exe --build -j 2 -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
      -I"$ROOT/core/include" -I"$G6LC_AI_INC_DIR" -GLanes=4 \
      "$ROOT/core/include/config_pkg.sv" "$G6LC_AI_RTL_DIR/include/g6lc_ai_fp_pkg.sv" \
      "$G6LC_AI_RTL_DIR/g6lc_ai_pe_dot_float.sv" "$ROOT/verif/tb/ai_island/pe_dot_float_main.cpp" \
      --top-module g6lc_ai_pe_dot_float -Mdir "$OUT/float" -o pe_dot_float
    "$OUT/float/pe_dot_float" ;;
  policy|subcode)
    policy_top=tb_g6lc_ai_policy_pipeline
    policy_define=G6LC_HYP8_POLICY_PIPELINE_TEST
    if [[ "$MODE" == subcode ]]; then
      policy_top=tb_g6lc_ai_policy_subcode_results
      policy_define=G6LC_HYP8_SUBCODE_RESULT_TEST
    fi
    /usr/bin/verilator --binary --timing -j 2 --assert -Wall -Wno-fatal -Wno-TIMESCALEMOD \
      -D"$policy_define" \
      -Werror-WIDTH -Werror-LATCH -Werror-MULTIDRIVEN -Werror-UNOPTFLAT \
      -I"$ROOT/core/include" -I"$G6LC_AI_RTL_DIR/include" \
      "$ROOT/core/include/config_pkg.sv" "$ROOT/core/include/g6lc64_ooo_config_pkg.sv" \
      "$G6LC_AI_RTL_DIR/include/g6lc_ai_policy_pkg.sv" \
      "$G6LC_AI_RTL_DIR/g6lc_ai_mul_seq.sv" "$G6LC_AI_RTL_DIR/g6lc_ai_policy_codec.sv" \
      "$G6LC_AI_RTL_DIR/g6lc_ai_policy_subcode.sv" "$G6LC_AI_RTL_DIR/g6lc_ai_policy_topology.sv" \
      "$G6LC_AI_RTL_DIR/g6lc_ai_policy_publish.sv" "$G6LC_AI_RTL_DIR/g6lc_ai_policy_steer.sv" \
      "$ROOT/verif/tb/ai_island/tb_g6lc_ai_policy_steer.sv" \
      --top-module "$policy_top" --Mdir "$OUT/policy" -o policy_pipeline
    "$OUT/policy/policy_pipeline"
    if [[ "$MODE" == subcode ]]; then
      if "$OUT/policy/policy_pipeline" +negative_subcode_oracle > "$OUT/negative-oracle.log" 2>&1; then
        echo "FAIL subcode oracle negative unexpectedly passed"; exit 1
      fi
      grep -q 'subcode result p=' "$OUT/negative-oracle.log"
      echo "PASS subcode oracle negative detected"
    fi ;;
  inval)
    AI_INVAL_QUEUE_OUT="$OUT/inval" bash verif/tb/ai_island/run-inval-queue.sh ;;
  island)
    AI_ISLAND_DMA_OUT="$OUT/island" bash verif/tb/ai_island/run-ai-island-dma.sh ;;
  gemm|wide)
    verilator() { /usr/bin/verilator "$@" --assert -j 2 -DG6LC_AI_HYP_R19 -DG6LC_AI_HYP_R20_CHECK; }
    export -f verilator
    if [[ "$MODE" == wide ]]; then
      AI_GEMM_WIDE_OUT="$OUT/wide" bash verif/tb/ai_island/run-gemm-wide.sh
    else
      export AI_GEMM_BACKEND_OUT="$OUT/backend"
      export AI_GEMM_DPF_LIST="${AI_GEMM_DPF_LIST:-0 2}"
      export MAX_K=64 MAX_N=64 REUSE_EN=1
      bash verif/tb/ai_island/run-gemm-backend.sh
      for dpf in $AI_GEMM_DPF_LIST; do
        for test_case in review_accumulate review_signed review_protocol review_slots review_fp32_add; do
          "$OUT/backend-n1-dpf$dpf/tb_g6lc_ai_gemm_backend" "+$test_case"
        done
      done
    fi ;;
  *) echo "Unknown mode: $MODE" >&2; exit 2 ;;
esac
echo "PASS focused-gate $MODE $TAG"
