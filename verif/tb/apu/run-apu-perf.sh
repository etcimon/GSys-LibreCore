#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# APU throughput dev loop (performance-area-scalability.md §8.2 TP0, §9.3
# FP0, §11): build the three perf benches, run the fixed cohort, collect the
# counter lines into one capture and compare it with the frozen baseline.
#
#   bash verif/tb/apu/run-apu-perf.sh            # run + gate against the last
#                                                # admitted state, then report
#                                                # progress against the origin
#   bash verif/tb/apu/run-apu-perf.sh --admit    # run + gate, then record this
#                                                # state as the admitted one
#   bash verif/tb/apu/run-apu-perf.sh --freeze   # run + write the origin (once;
#                                                # APU_PERF_FORCE=1 to rewrite)
#   bash verif/tb/apu/run-apu-perf.sh --admit-from CAPTURE
#                                                # no simulation: gate a full
#                                                # capture pulled from a remote
#                                                # leaf (perf stage) and record
#                                                # it as the admitted state
#   APU_PERF_BENCHES="rast" bash ...             # subset (diff uses --subset)
#   APU_PERF_ARMS="" bash ...                    # skip the control arms (subset)
#
# Control arms (APU_PERF_ARMS, default "rc0 jitter"; part of the full cohort):
#   rc0     the shader suite rebuilt with -GRowCacheEntries=0 (long decode
#           only).  Must check the same work as the cached build and report
#           no row hit; captured as run "shwave-rc0" so the long path is
#           gated against regressions as well.
#   jitter  the frame cohort again with +mp_lat_min=1 +mp_lat_max=20
#           +mp_ready_pct=60.  Every session must pass with the same cases
#           and checks as its zero-jitter run; cycles are not captured.
# The harness of record is the remote testharness: the "perf" stage of
# run-apu-regress.sh runs this script on an isolated snapshot
# (APU_LEAF_STAGES=perf bash verif/tb/apu/run-apu-remote-leaf.sh) and the
# collected output/perf/capture.json is admitted here with --admit-from.
#
# Two captures live beside this script.  apu-perf-baseline.json is the
# origin the gates G-T1 / G-F1 are measured from and is written once.
# apu-perf-current.json is the last admitted state and is what a new pass
# must not regress.
# Rule: a throughput pass is admitted only when this script prints
# "OK same checked work; no cycle regression" (apu_perf.py diff exit 0).
# It is a dev loop, not qualification: simulator PGO is off (same results,
# shorter build; APU_SIM_PGO=1 restores it) and the memory slave is the
# ideal one (latency 1, always ready), so cycle totals are lower bounds.
# The full gates stay run-apu-ci.sh / run-apu-regress.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/verif/tb/apu"
export CVA6_REPO_DIR="$ROOT"
export APU_SIM_PGO="${APU_SIM_PGO:-0}"
source "$HERE/local-verilator.sh"
OUT="${APU_PERF_OUT:-$APU_BUILD_CACHE/perf}"
BASE="${APU_PERF_BASELINE:-$HERE/apu-perf-baseline.json}"
BENCHES="${APU_PERF_BENCHES:-rast shwave vgtop}"
# Frame cohort: one session per stage the frame program touches.  Keep the
# list stable — the baseline is keyed by these names.
FRAME_SESSIONS="${APU_PERF_SESSIONS:-ue_gpos_tri_1 ue_gpos_grad_1 \
ue_gpos_persp_1 ue_gpos_deriv2_1 ue_gpos_dtest_1 ue_gpos_dbias_1 \
ue_gpos_blend_1 ue_gpos_mrt4_1 ue_gpos_stencil_1 ue_gpos_inst_1 \
ue_gpos_line_1 ue_gpos_ftex_1 ue_gpos_ftexl_1 ue_gpos_vtex_1 \
ue_cpos_vec4arith_1 ue_cpos_math450_1 ue_cpos_xfer_big_1 \
ue_cpos_clear_rgba8_1}"
CUR="${APU_PERF_CURRENT:-$HERE/apu-perf-current.json}"
ARMS="${APU_PERF_ARMS-rc0 jitter}"
for a in $ARMS; do
  case "$a" in rc0|jitter) ;; *) echo "unknown arm $a" >&2; exit 2 ;; esac
done
has_arm() { [[ " $ARMS " == *" $1 "* ]]; }
freeze=0; admit=0
case "${1:-}" in
  --freeze) freeze=1 ;;
  --admit)  admit=1 ;;
  --admit-from)
    # Gate an existing full capture (a remote perf-stage result) and record
    # it.  The capture must hold every run of the admitted state: the diff
    # runs without --subset, so a missing run is a failure.
    cap="${2:-}"
    [[ -n "$cap" && -f "$cap" ]] || { echo "usage: $0 --admit-from CAPTURE" >&2; exit 2; }
    [[ -f "$BASE" ]] || { echo "PERF: no origin at $BASE (run --freeze)"; exit 3; }
    gate="$BASE"; [[ -f "$CUR" ]] && gate="$CUR"
    echo "PERF: gate $cap against $(basename "$gate")"
    python3 -B "$HERE/apu_perf.py" diff "$gate" "$cap"
    if [[ "$gate" != "$BASE" ]]; then
      echo "PERF: progress against the origin $(basename "$BASE") (not a gate)"
      python3 -B "$HERE/apu_perf.py" diff --subset "$BASE" "$cap" || true
    fi
    cp "$cap" "$CUR"
    echo "PERF: admitted -> $CUR"
    exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--freeze|--admit|--admit-from CAPTURE]" >&2; exit 2 ;;
esac
if [[ "$freeze" == 1 && -f "$BASE" && "${APU_PERF_FORCE:-0}" != 1 ]]; then
  echo "PERF: origin $BASE exists; set APU_PERF_FORCE=1 to rewrite it" >&2
  exit 2
fi
mkdir -p "$OUT"
logs=()
njit=0
t0=$SECONDS
for b in $BENCHES; do
  case "$b" in
    rast)
      APU_RAST_OUT="$OUT/rast" bash "$HERE/run-apu-rast.sh" \
        > "$OUT/rast.console.log" 2>&1 || {
          tail -n 40 "$OUT/rast.console.log"; echo "PERF: rast FAILED"; exit 1; }
      logs+=("rast=$OUT/rast/sim.log") ;;
    shwave)
      APU_SHWAVE_OUT="$OUT/shwave" bash "$HERE/run-apu-shwave.sh" \
        > "$OUT/shwave.console.log" 2>&1 || {
          tail -n 40 "$OUT/shwave.console.log"; echo "PERF: shwave FAILED"; exit 1; }
      logs+=("shwave=$OUT/shwave/sim.log")
      if has_arm rc0; then
        APU_SHWAVE_OUT="$OUT/shwave-rc0" \
          APU_SHWAVE_GFLAGS="-GRowCacheEntries=0" \
          bash "$HERE/run-apu-shwave.sh" \
          > "$OUT/shwave-rc0.console.log" 2>&1 || {
            tail -n 40 "$OUT/shwave-rc0.console.log"
            echo "PERF: shwave rc0 arm FAILED"; exit 1; }
        # same checked work as the cached build, and no row hit at all
        w0="$(grep '^PASS tb_g6lc_apu_shwave ' "$OUT/shwave/sim.log" |
              grep -o 'cases=[0-9]* checks=[0-9]*')"
        w1="$(grep '^PASS tb_g6lc_apu_shwave ' "$OUT/shwave-rc0/sim.log" |
              grep -o 'cases=[0-9]* checks=[0-9]*')"
        [[ -n "$w0" && "$w0" == "$w1" ]] || {
          echo "PERF: shwave rc0 arm FAILED: work '$w1' != cached '$w0'"; exit 1; }
        if grep -q '^PERF .* rhit=[1-9]' "$OUT/shwave-rc0/sim.log"; then
          echo "PERF: shwave rc0 arm FAILED: row hits with RowCacheEntries=0"; exit 1
        fi
        grep -q '^PERF .* rhit=0' "$OUT/shwave-rc0/sim.log" || {
          echo "PERF: shwave rc0 arm FAILED: no rhit counter in the PERF lines"; exit 1; }
        logs+=("shwave-rc0=$OUT/shwave-rc0/sim.log")
        echo "PERF: shwave rc0 arm OK ($w1, rhit=0)"
      fi ;;
    vgtop)
      APU_VGTOP_OUT="$OUT/vgtop" bash "$HERE/build-apu-vgtop.sh" \
        > "$OUT/vgtop.console.log" 2>&1 || {
          tail -n 40 "$OUT/vgtop.console.log"; echo "PERF: vgtop build FAILED"; exit 1; }
      for v in $FRAME_SESSIONS; do
        xok=()
        case "$v" in ue_cpos_*) xok=(+xf_ok) ;; esac
        (cd "$HERE" && "$OUT/vgtop/sim/tb_g6lc_apu_vgtop" +vec="$v" \
           "${xok[@]}") > "$OUT/vgtop-$v.log" 2>&1 || true
        grep -q '^PASS tb_g6lc_apu_vgtop ' "$OUT/vgtop-$v.log" || {
          tail -n 20 "$OUT/vgtop-$v.log"; echo "PERF: vgtop $v FAILED"; exit 1; }
        logs+=("vgtop:$v=$OUT/vgtop-$v.log")
        if has_arm jitter; then
          (cd "$HERE" && "$OUT/vgtop/sim/tb_g6lc_apu_vgtop" +vec="$v" \
             "${xok[@]}" +mp_lat_min=1 +mp_lat_max=20 +mp_ready_pct=60) \
             > "$OUT/vgtop-jitter-$v.log" 2>&1 || true
          j0="$(grep '^PASS tb_g6lc_apu_vgtop ' "$OUT/vgtop-$v.log" |
                grep -o 'cases=[0-9]* checks=[0-9]*')"
          j1="$(grep '^PASS tb_g6lc_apu_vgtop ' "$OUT/vgtop-jitter-$v.log" |
                grep -o 'cases=[0-9]* checks=[0-9]*' || true)"
          [[ -n "$j0" && "$j0" == "$j1" ]] || {
            tail -n 20 "$OUT/vgtop-jitter-$v.log"
            echo "PERF: vgtop jitter arm $v FAILED: '$j1' != '$j0'"; exit 1; }
          njit=$((njit + 1))
        fi
      done
      if has_arm jitter; then
        echo "PERF: vgtop jitter arm OK ($njit sessions, same cases and checks)"
      fi ;;
    *) echo "unknown bench $b" >&2; exit 2 ;;
  esac
  echo "PERF: $b done at +$((SECONDS - t0))s"
done
python3 -B "$HERE/apu_perf.py" collect -o "$OUT/capture.json" "${logs[@]}"
if [[ "$freeze" == 1 ]]; then
  cp "$OUT/capture.json" "$BASE"
  echo "PERF: origin frozen -> $BASE"
  exit 0
fi
[[ -f "$BASE" ]] || { echo "PERF: no origin at $BASE (run --freeze)"; exit 3; }
full=1
[[ "$BENCHES" == "rast shwave vgtop" && -z "${APU_PERF_SESSIONS:-}" &&
   "$ARMS" == "rc0 jitter" ]] || full=0
sub=()
[[ "$full" == 1 ]] || sub=(--subset)
gate="$BASE"
[[ -f "$CUR" ]] && gate="$CUR"
echo "PERF: gate against $(basename "$gate")"
python3 -B "$HERE/apu_perf.py" diff "${sub[@]}" "$gate" "$OUT/capture.json"
if [[ "$gate" != "$BASE" ]]; then
  echo "PERF: progress against the origin $(basename "$BASE") (not a gate)"
  python3 -B "$HERE/apu_perf.py" diff "${sub[@]}" "$BASE" "$OUT/capture.json" \
    || true
fi
if [[ "$admit" == 1 ]]; then
  [[ "$full" == 1 ]] || { echo "PERF: --admit needs the full cohort"; exit 2; }
  cp "$OUT/capture.json" "$CUR"
  echo "PERF: admitted -> $CUR"
fi
