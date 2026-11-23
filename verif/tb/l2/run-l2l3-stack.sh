#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# run-l2l3-stack.sh — build + run the standalone L2->L3 stack leaf
# (tb_g6lc_l2l3_stack.sv). Proves L3 hits serve correct data and the stack
# stays coherent across write / ATOP / NC / back-inval.
#
#   STACK_RTL=<repo-rel dir>  tree holding l2_cache/ + l3_cache/
#                             (default build-platform/workspace/hyp/
#                              hyp_redesign_corev_apu_8fo4/corev_apu;
#                              corev_apu = non-hyp tree)
#   STACK_ARMS="hyp8 wu0 pw0 ts0"   feature arms (default "hyp8"):
#       hyp8 = WRITE_UPDATE=1 POSTED_WRITES=1 TAG_SRAM=1 (both levels)
#       wu0  = WRITE_UPDATE=0 at both levels
#       pw0  = POSTED_WRITES=0 at both levels
#       ts0  = TAG_SRAM=0 at both levels
#   STACK_SEEDS="1 2 3"     positive-run seeds (default "1 2 3")
#   STACK_OUT=<dir>         output root (default /tmp/g6lc-l2l3-stack)
#   STACK_OPS=4000          P7 random-op count (+ops)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
STACK_RTL="${STACK_RTL:-build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu}"
[[ "$STACK_RTL" =~ ^[A-Za-z0-9_./-]+$ && "$STACK_RTL" != *..* ]] || { echo "[l2l3] bad STACK_RTL" >&2; exit 2; }
STACK_ARMS="${STACK_ARMS:-hyp8}"
STACK_SEEDS="${STACK_SEEDS:-1 2 3}"
STACK_OPS="${STACK_OPS:-4000}"
OUT_BASE="${STACK_OUT:-/tmp/g6lc-l2l3-stack}"
mkdir -p "$OUT_BASE"

# Stock Verilator 5.020 miscompiles g6lc_l2_top's back-inval match decode:
# tag_match_index/tag_match_tag select self_inval_addr regardless of
# l2_back_inval_valid_i, so back-invalidations clear the wrong set and stale
# data is served (observed STACK_DATA_MISMATCH under 5.020; identical RTL +
# bench passes clean under 5.008). Pin the managed 5.008 toolchain the hyp8
# flow targets; VERILATOR env overrides, PATH verilator is the last resort.
VERILATOR="${VERILATOR:-}"
if [ -z "$VERILATOR" ]; then
  for c in \
    "$REPO_ROOT/build-platform/workspace/tooling/verilator-v5.008-wsl/bin/verilator" \
    "$REPO_ROOT/build-platform/workspace/tooling/verilator-v5.008/bin/verilator" \
    "$REPO_ROOT/build-platform/workspace/tooling/oss-cad-suite/build-v5.008/bin/verilator" \
    /root/tools/verilator-v5.008/bin/verilator \
    /opt/testharness/toolchains/verilator-v5.008/bin/verilator \
    "$(command -v verilator 2>/dev/null || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && VERILATOR="$c" && break
  done
fi
# Resolve a bare command name (e.g. VERILATOR=verilator) to its path.
if [ -n "$VERILATOR" ] && ! [ -x "$VERILATOR" ]; then
  VERILATOR="$(command -v "$VERILATOR" 2>/dev/null || true)"
fi
[ -n "$VERILATOR" ] && [ -x "$VERILATOR" ] || { echo "[l2l3] no verilator" >&2; exit 2; }
ulimit -c 0
warning_args=()
if "$VERILATOR" -Wno-GENUNNAMED --version >/dev/null 2>&1; then warning_args+=(-DL2TB_GENUNNAMED); fi
if "$VERILATOR" -Wno-WIDTHEXPAND --version >/dev/null 2>&1; then warning_args+=(-Wno-WIDTHEXPAND); fi
"$VERILATOR" --version

src_list() {
  # repo-relative source list for the selected RTL tree
  printf '%s\n' \
    "vendor/pulp-platform/axi/src/axi_pkg.sv" \
    "vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
    "$STACK_RTL/l2_cache/g6lc_l2_pkg.sv" \
    "$STACK_RTL/l2_cache/g6lc_l2_tag.sv" \
    "$STACK_RTL/l2_cache/g6lc_l2_data.sv" \
    "$STACK_RTL/l2_cache/g6lc_l2_mshr.sv" \
    "$STACK_RTL/l2_cache/g6lc_l2_wtrk.sv" \
    "$STACK_RTL/l2_cache/g6lc_l2_pf.sv" \
    "$STACK_RTL/l2_cache/g6lc_l2_top.sv" \
    "$STACK_RTL/l3_cache/g6lc_l3_pkg.sv" \
    "$STACK_RTL/l3_cache/g6lc_l3_top.sv" \
    "verif/tb/l2/tb_g6lc_l2l3_stack.sv"
}

arm_params() {
  case "$1" in
    hyp8) echo "-GL2_WRITE_UPDATE=1 -GL3_WRITE_UPDATE=1 -GL2_POSTED_WRITES=1 -GL3_POSTED_WRITES=1 -GL2_TAG_SRAM=1 -GL3_TAG_SRAM=1" ;;
    wu0)  echo "-GL2_WRITE_UPDATE=0 -GL3_WRITE_UPDATE=0 -GL2_POSTED_WRITES=1 -GL3_POSTED_WRITES=1 -GL2_TAG_SRAM=1 -GL3_TAG_SRAM=1" ;;
    pw0)  echo "-GL2_WRITE_UPDATE=1 -GL3_WRITE_UPDATE=1 -GL2_POSTED_WRITES=0 -GL3_POSTED_WRITES=0 -GL2_TAG_SRAM=1 -GL3_TAG_SRAM=1" ;;
    ts0)  echo "-GL2_WRITE_UPDATE=1 -GL3_WRITE_UPDATE=1 -GL2_POSTED_WRITES=1 -GL3_POSTED_WRITES=1 -GL2_TAG_SRAM=0 -GL3_TAG_SRAM=0" ;;
    *) echo "[l2l3] unknown arm $1" >&2; exit 2 ;;
  esac
}

negatives_caught=0
arms_run=""
for arm in $STACK_ARMS; do
  arms_run="$arms_run $arm"
  OUT="$OUT_BASE/$arm"
  mkdir -p "$OUT"
  echo "[l2l3] arm=$arm out=$OUT"

  # isolated source copy + sha256 pinning (same pattern as run-l2-tb.sh)
  mapfile -t rel < <(src_list)
  inputs=("${rel[@]}" "verif/tb/l2/run-l2l3-stack.sh")
  live=()
  for r in "${inputs[@]}"; do live+=("$REPO_ROOT/$r"); done
  sha256sum "${live[@]}" > "$OUT/live-sources.sha256"
  for i in "${!live[@]}"; do
    dest="$OUT/source/${live[$i]#"$REPO_ROOT/"}"
    mkdir -p "$(dirname "$dest")"
    cp -- "${live[$i]}" "$dest"
    cmp -- "${live[$i]}" "$dest"
  done
  (cd "$OUT/source" && sha256sum --check --status "../live-sources.sha256" 2>/dev/null || true)
  sources=()
  for r in "${rel[@]}"; do sources+=("$OUT/source/$r"); done
  (cd "$OUT/source" && find . -name '*.sv' -o -name '*.sh' | sort | xargs sha256sum) > "$OUT/sources.sha256"

  # shellcheck disable=SC2086
  "$VERILATOR" --binary --timing --assert -Wall -Wno-TIMESCALEMOD -Wno-UNUSED \
    "${warning_args[@]}" -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-DECLFILENAME -Wno-VARHIDDEN \
    -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINMISSING -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-fatal \
    "${sources[@]}" \
    --top-module tb_g6lc_l2l3_stack \
    $(arm_params "$arm") \
    -GMEM_LATENCY=8 \
    -Mdir "$OUT/obj" -o tb_g6lc_l2l3_stack 2>&1 | tee "$OUT/build.log"
  [[ -x "$OUT/obj/tb_g6lc_l2l3_stack" ]] || { echo "[l2l3] $arm build FAIL — $OUT/build.log"; exit 1; }
  sha256sum "$OUT/obj/tb_g6lc_l2l3_stack" > "$OUT/executable.sha256"

  for seed in $STACK_SEEDS; do
    "$OUT/obj/tb_g6lc_l2l3_stack" +seed="$seed" +ops="$STACK_OPS" \
      2>&1 | tee "$OUT/sim-seed$seed.log" || true
    n_pass=$(grep -cFx '[STACK] RESULT pass' "$OUT/sim-seed$seed.log" || true)
    if [[ "$n_pass" != 1 ]] || grep -qE 'FAIL|%Error|%Fatal' "$OUT/sim-seed$seed.log"; then
      echo "[l2l3] $arm seed=$seed FAIL — $OUT/sim-seed$seed.log"; exit 1
    fi
    grep -E '^\[STACK\] (phase|totals|RESULT)' "$OUT/sim-seed$seed.log" | tail -10
  done

  # negative 1: oracle flip must produce STACK_DATA_MISMATCH
  "$OUT/obj/tb_g6lc_l2l3_stack" +seed=1 +ops="$STACK_OPS" +oracle_negative=1 \
    2>&1 | tee "$OUT/sim-neg-oracle.log" || true
  if ! grep -q 'STACK_DATA_MISMATCH' "$OUT/sim-neg-oracle.log" || \
     grep -qFx '[STACK] RESULT pass' "$OUT/sim-neg-oracle.log"; then
    echo "[l2l3] $arm oracle_negative did not fail — $OUT/sim-neg-oracle.log"; exit 1
  fi
  negatives_caught=$((negatives_caught + 1))

  # negative 2: skip ONLY the L3 back-inval -> stale L3 data must mismatch
  "$OUT/obj/tb_g6lc_l2l3_stack" +seed=1 +ops="$STACK_OPS" +mut_skip_l3_inval=1 \
    2>&1 | tee "$OUT/sim-neg-skipl3.log" || true
  if ! grep -q 'STACK_DATA_MISMATCH.*phase=dma_backinval' "$OUT/sim-neg-skipl3.log" || \
     grep -qFx '[STACK] RESULT pass' "$OUT/sim-neg-skipl3.log"; then
    echo "[l2l3] $arm mut_skip_l3_inval did not fail at dma_backinval — $OUT/sim-neg-skipl3.log"; exit 1
  fi
  negatives_caught=$((negatives_caught + 1))
done

echo "PASS run-l2l3-stack (arms=${arms_run# }, seeds=\"$STACK_SEEDS\", negatives caught=$negatives_caught) — $OUT_BASE"
