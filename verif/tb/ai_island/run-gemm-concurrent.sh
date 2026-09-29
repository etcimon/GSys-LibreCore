#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# N-engine concurrent GEMM vs one shared class-0 DRAM slave (not LiteDRAM,
# not Variane).  Sweeps engine count x channel count and prints serial vs
# concurrent wall cycles per format/sharing mode.  Sim cycles on the SRAM
# model only -- a contention answer, not MAC/s.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUT="${AI_GEMM_CONC_OUT:-$ROOT/build-platform/workspace/build/g6lc-ai-gemm-concurrent}"
JOBS="${AI_GEMM_CONC_JOBS:-0}"
if [[ "$JOBS" == 0 ]]; then
  JOBS="$( (command -v nproc >/dev/null 2>&1 && nproc) || echo 2 )"
fi
CCACHE_DIR="${CCACHE_DIR:-$ROOT/build-platform/workspace/build/ccache-gemm-concurrent}"
if command -v ccache >/dev/null 2>&1; then
  export OBJCACHE=ccache CCACHE_DIR
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-16G}"
  export CCACHE_COMPILERCHECK="${CCACHE_COMPILERCHECK:-content}"
  mkdir -p "$CCACHE_DIR"
fi
VA_TURBO="${VA_TURBO:-1}"
DOT_PIPE_FLOAT="${DOT_PIPE_FLOAT:-0}"
PE_LANES="${PE_LANES:-0}"
MAX_DIM="${MAX_DIM:-0}"
DRAM_CLASS="${DRAM_CLASS:-0}"
# Job geometry. 8/8/16 is the measured default and every published cycle number
# is at it; the axis exists because shape moves the answer (a decode row is
# traffic-bound where a square tile is not), and the memory slots are derived
# from these so a larger geometry no longer needs a hand-edited memory map.
JOB_M="${JOB_M:-8}"
JOB_N="${JOB_N:-8}"
JOB_K="${JOB_K:-16}"
RUN_TIMEOUT="${AI_GEMM_CONC_TIMEOUT:-300}"
VERILATOR="${VERILATOR:-verilator}"
if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]] || (( JOBS > 256 )); then
  echo "FAIL AI_GEMM_CONC_JOBS must be 0 (auto) or 1..256" >&2
  exit 2
fi
case "$VA_TURBO" in 0|1) ;; *) echo "FAIL VA_TURBO must be 0 or 1" >&2; exit 2;; esac
case "$DOT_PIPE_FLOAT" in 0|1) ;; *) echo "FAIL DOT_PIPE_FLOAT must be 0 or 1" >&2; exit 2;; esac
case "$PE_LANES" in 0|8|16|32|64|128|256) ;; *) echo "FAIL invalid PE_LANES" >&2; exit 2;; esac
if [[ ! "$MAX_DIM" =~ ^(0|[1-9][0-9]*)$ ]] || (( MAX_DIM != 0 && (MAX_DIM < 16 || MAX_DIM > 256) )); then
  echo "FAIL MAX_DIM must be 0 or 16..256" >&2
  exit 2
fi
case "$DRAM_CLASS" in 0|1) ;; *) echo "FAIL DRAM_CLASS must be 0 or 1" >&2; exit 2;; esac
for g in JOB_M JOB_N JOB_K; do
  v="${!g}"
  if [[ ! "$v" =~ ^[1-9][0-9]*$ ]] || (( v > 256 )); then
    echo "FAIL $g must be 1..256" >&2
    exit 2
  fi
done
# INT4 stages a packed nibble row, and the loader only reads 8-byte-aligned rows
# back correctly; k must therefore keep the row stride on an 8-byte boundary.
# Caught by a signed INT4 tile failing golden at JOB_K=8 -- all-ones fixtures
# pass there, because uniform data cannot detect a shifted read.
if (( JOB_K % 16 != 0 )); then
  echo "FAIL JOB_K must be a multiple of 16 while INT4 is in the format tables" >&2
  exit 2
fi
if [[ ! "$RUN_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "FAIL AI_GEMM_CONC_TIMEOUT must be positive seconds" >&2
  exit 2
fi
if ! command -v "$VERILATOR" >/dev/null 2>&1; then
  echo "FAIL no verilator: $VERILATOR" >&2
  exit 127
fi
if ! command -v timeout >/dev/null 2>&1; then
  echo "FAIL no timeout utility" >&2
  exit 127
fi
CCELLS="$ROOT/vendor/pulp-platform/common_cells"
AXI="$ROOT/vendor/pulp-platform/axi"
build_cfg() {
  local nch="$1"
  local eng="$2"
  local mdir="$3"
  local rc
  mkdir -p "$mdir"
  printf 'running\n' >"$mdir/build.status"
  printf 'not-run\n' >"$mdir/run.status"
  : >"$mdir/run.log"
  printf 'CONFIG engines=%s channels=%s va_turbo=%s jobs=%s out=%s\n' "$eng" "$nch" "$VA_TURBO" "$JOBS" "$mdir"
  if "$VERILATOR" --binary --timing --assert -j "$JOBS" -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED -Wno-UNOPTFLAT \
    -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
    -GNCH="$nch" \
    -GN_ENGINES="$eng" \
    -GVA_TURBO="$VA_TURBO" \
    -GDOT_PIPE_FLOAT="$DOT_PIPE_FLOAT" \
    -GPE_LANES="$PE_LANES" \
    -GMAX_DIM="$MAX_DIM" \
    -GJOB_M="$JOB_M" \
    -GJOB_N="$JOB_N" \
    -GJOB_K="$JOB_K" \
    -GDRAM_CLASS="$DRAM_CLASS" \
  -I"$AXI/include" \
  -I"$CCELLS/include" \
  -I"$ROOT/core/include" \
  -I"$ROOT/corev_apu/include" \
  -I"$ROOT/corev_apu/ai_island/include" \
  "$CCELLS/src/cf_math_pkg.sv" \
  "$CCELLS/src/lzc.sv" \
  "$CCELLS/src/counter.sv" \
  "$CCELLS/src/delta_counter.sv" \
  "$CCELLS/src/fifo_v3.sv" \
  "$CCELLS/src/spill_register_flushable.sv" \
  "$CCELLS/src/spill_register.sv" \
  "$CCELLS/src/rr_arb_tree.sv" \
  "$AXI/src/axi_pkg.sv" \
  "$AXI/src/axi_intf.sv" \
  "$AXI/src/axi_id_prepend.sv" \
  "$AXI/src/axi_mux.sv" \
  "$AXI/src/axi_demux.sv" \
  "$AXI/src/axi_cut.sv" \
  "$ROOT/core/include/config_pkg.sv" \
  "$ROOT/corev_apu/ai_island/include/g6lc_ai_policy_pkg.sv" \
  "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
  "$ROOT/common/local/util/tc_sram_wrapper.sv" \
  "$ROOT/corev_apu/axi_mem_if/src/axi2mem.sv" \
  "$ROOT/common/local/util/sram.sv" \
  "$ROOT/corev_apu/include/g6lc_ai_island_cfg_pkg.sv" \
  "$ROOT/corev_apu/src/g6lc_ai_dram_backend.sv" \
  "$ROOT/corev_apu/ai_island/include/g6lc_ai_fp_pkg.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot_float.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_pe_dot_float_pipe.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_tile_sram.sv" \
  "$ROOT/corev_apu/ai_island/g6lc_ai_gemm_seq.sv" \
  "$ROOT/verif/tb/ai_island/tb_g6lc_ai_gemm_concurrent.sv" \
    --top-module tb_g6lc_ai_gemm_concurrent \
    -Mdir "$mdir" -o tb_g6lc_ai_gemm_concurrent >"$mdir/build.log" 2>&1; then
    printf '0\n' >"$mdir/build.status"
  else
    rc=$?
    printf '%s\n' "$rc" >"$mdir/build.status"
    tail -80 "$mdir/build.log" >&2
    echo "FAIL build status=$rc log=$mdir/build.log" >&2
    exit "$rc"
  fi
  if timeout --signal=TERM --kill-after=10s "${RUN_TIMEOUT}s" "$mdir/tb_g6lc_ai_gemm_concurrent" >"$mdir/run.log" 2>&1; then
    printf '0\n' >"$mdir/run.status"
  else
    rc=$?
    printf '%s\n' "$rc" >"$mdir/run.status"
    tail -80 "$mdir/run.log" >&2
    echo "FAIL simulation status=$rc log=$mdir/run.log" >&2
    exit "$rc"
  fi
  cat "$mdir/run.log"
  if ! grep -q '^PASS g6lc_ai_gemm_concurrent ' "$mdir/run.log"; then
    echo "FAIL missing simulation PASS log=$mdir/run.log" >&2
    exit 1
  fi
}
# Engine count is structural: one build per value.  1 is the degenerate
# baseline (serial == concurrent expected), 2 and 4 the measured points.
read -r -a ENG_LIST <<< "${AI_GEMM_CONC_ENGINES:-1 2 4}"
# Channels at the extremes: the earlier sweep showed one engine is not
# bandwidth-starved, so the interesting contrast is minimum vs provisioned.
read -r -a NCH_LIST <<< "${AI_GEMM_CONC_CHANNELS:-1 4}"
if (( ${#ENG_LIST[@]} == 0 || ${#NCH_LIST[@]} == 0 )); then
  echo "FAIL empty engine/channel sweep" >&2
  exit 2
fi
for eng in "${ENG_LIST[@]}"; do
  case "$eng" in 1|2|4) ;; *) echo "FAIL engines must be 1, 2 or 4 (8 KiB slots)" >&2; exit 2;; esac
done
for nch in "${NCH_LIST[@]}"; do
  case "$nch" in 1|2|4|8) ;; *) echo "FAIL channels must be 1, 2, 4 or 8" >&2; exit 2;; esac
done
for eng in "${ENG_LIST[@]}"; do
  for nch in "${NCH_LIST[@]}"; do
    build_cfg "$nch" "$eng" "${OUT}/e${eng}n${nch}-v${VA_TURBO}-p${DOT_PIPE_FLOAT}-l${PE_LANES}-d${MAX_DIM}-c${DRAM_CLASS}"
  done
done
echo "PASS tb_g6lc_ai_gemm_concurrent eng=${ENG_LIST[*]} nch=${NCH_LIST[*]} va_turbo=$VA_TURBO out=$OUT"
