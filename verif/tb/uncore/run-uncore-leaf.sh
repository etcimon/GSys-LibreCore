#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Standalone leaf testbenches for the small self-contained uncore coherence /
# invalidation / mux leaf modules that previously only ran through the remote
# review harnesses (run_retain_review.py, run_sf_review.py, run_mux_review.py):
#   tb_g6lc_inval_retain      — core/cache_subsystem invalidation retention
#   tb_g6lc_ooo_snoop_filter  — OoO-core snoop filter (SRAM-backed)
#   tb_g6lc_snoop_filter      — in-order snoop filter
#   tb_g6lc_axi_2to1_mux      — core/Ara AXI response-ownership mux
# (tb_g6lc_hpdcache_cmo needs the full hpdcache subsystem and stays remote-only;
# the l2-dir leaves are covered by run-l2-leaf.sh / run-coherence-hub.sh.)
#
#   bash verif/tb/uncore/run-uncore-leaf.sh              # all benches
#   UNCORE_BENCH=snoop_filter bash verif/tb/uncore/run-uncore-leaf.sh
#
# Knobs (env):
#   UNCORE_OUT=<dir>       output dir (default /tmp/g6lc-uncore-leaf)
#   UNCORE_BENCH=all|inval_retain|ooo_snoop_filter|snoop_filter|axi_2to1_mux
#   UNCORE_NEGATIVE=0|1    also run each scenario negative control (default 0)
#   UNCORE_RTL=<repo-rel>  RTL root holding coherence/, src/, cache_subsystem/
#                          (default corev_apu for coherence+src; inval_retain
#                          lives under core/cache_subsystem — see below)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
UNCORE_RTL="${UNCORE_RTL:-corev_apu}"
[[ "$UNCORE_RTL" =~ ^[A-Za-z0-9_./-]+$ && "$UNCORE_RTL" != *..* ]] || { echo "[uncore-leaf] bad UNCORE_RTL" >&2; exit 2; }
OUT="${UNCORE_OUT:-/tmp/g6lc-uncore-leaf}"
mkdir -p "$OUT"
BENCH="${UNCORE_BENCH:-all}"
case "$BENCH" in all|inval_retain|ooo_snoop_filter|snoop_filter|axi_2to1_mux) ;; *) echo "[uncore-leaf] bad UNCORE_BENCH=$BENCH" >&2; exit 2;; esac
NEG="${UNCORE_NEGATIVE:-0}"

VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1; then
  for c in /root/tools/verilator-v5.008/bin/verilator \
           /opt/testharness/toolchains/verilator-v5.008/bin/verilator \
           "$ROOT/build-platform/workspace/tooling/linux-eda-suite/bin/verilator_bin"; do
    [ -x "$c" ] && VERILATOR="$c" && break
  done
fi
command -v "$VERILATOR" >/dev/null 2>&1 || { echo "[uncore-leaf] no verilator" >&2; exit 2; }
"$VERILATOR" --version
ulimit -c 0

R="$ROOT/$UNCORE_RTL"
VL_WARN=(-Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
         -Wno-LATCH -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-UNSIGNED \
         -Wno-DECLFILENAME)

# g6lc_l2_tb_pkg (AXI channel/transaction types) for the mux bench.
T="$OUT/types.sv"
sed -n '/^package g6lc_l2_tb_pkg;/,/^endpackage/p' \
  "$ROOT/verif/tb/l2/tb_g6lc_l2.sv" > "$T"
grep -q 'endpackage' "$T" || { echo "[uncore-leaf] g6lc_l2_tb_pkg extraction failed" >&2; exit 2; }

build() { # $1=name $2=top $3=outfile $4...=sources
  local name="$1" top="$2" out="$3"; shift 3
  local mdir="$OUT/$name"
  mkdir -p "$mdir"
  "$VERILATOR" --binary --timing "${VL_WARN[@]}" "$@" \
    --top-module "$top" -Mdir "$mdir" -o "$out" \
    > "$mdir/build.log" 2>&1 || {
      echo "[uncore-leaf] $name BUILD FAILED"; tail -n 40 "$mdir/build.log"; return 1; }
  echo "[uncore-leaf] $name build ok"
}

rc_all=0

# run_bench <binary> <pass-regex> <neg-arg> <scenarios...>
# Positive arm expects the pass marker; negative arm expects a Fatal/assert
# (the injected fault must be caught, not reach the pass marker).
run_bench() {
  local bin="$1" passre="$2" negarg="$3"; shift 3
  local scens=("$@")
  for s in "${scens[@]}"; do
    for neg in 0 1; do
      [ "$neg" = 1 ] && [ "$NEG" != 1 ] && continue
      local args=() log="$OUT/$(basename "$bin")-s$s-neg$neg.log"
      [ -n "$s" ] && args+=(+scenario="$s")
      [ "$neg" = 1 ] && [ -n "$negarg" ] && args+=("$negarg")
      set +e; "$bin" "${args[@]}" > "$log" 2>&1; local rc=$?; set -e
      if [ "$neg" = 0 ]; then
        if grep -qE "$passre" "$log"; then
          echo "[uncore-leaf] PASS $s neg=0"
        else
          echo "[uncore-leaf] FAIL $s neg=0 rc=$rc"; grep -iE "fatal|assert|error" "$log" | head -3
          rc_all=1
        fi
      else
        if grep -qE "$passre" "$log"; then
          echo "[uncore-leaf] FAIL $s neg=1 (passed despite fault — control broken)"
          rc_all=1
        elif grep -qiE "%fatal|assertion failed|%error|%stop" "$log"; then
          echo "[uncore-leaf] PASS $s neg=1 (fault detected)"
        else
          echo "[uncore-leaf] FAIL $s neg=1 rc=$rc (no detection, no pass)"
          grep -iE "fatal|assert|error" "$log" | head -3; rc_all=1
        fi
      fi
    done
  done
}

# ---- tb_g6lc_inval_retain : core/cache_subsystem ---------------------------
if [ "$BENCH" = all ] || [ "$BENCH" = inval_retain ]; then
  build inval_retain tb_g6lc_inval_retain ir_tb \
    "$ROOT/core/cache_subsystem/g6lc_inval_retain.sv" \
    "$ROOT/verif/tb/uncore/tb_g6lc_inval_retain.sv" || rc_all=1
  [ "$rc_all" = 0 ] && run_bench "$OUT/inval_retain/ir_tb" 'RTL_REVIEW_PASS' +oracle_negative 0 1 2
fi

# ---- tb_g6lc_ooo_snoop_filter : OoO snoop filter (SRAM-backed) --------------
if [ "$BENCH" = all ] || [ "$BENCH" = ooo_snoop_filter ]; then
  build ooo_snoop_filter tb_g6lc_ooo_snoop_filter osf_tb \
    "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
    "$R/coherence/g6lc_ooo_snoop_filter.sv" \
    "$ROOT/verif/tb/uncore/tb_g6lc_ooo_snoop_filter.sv" || rc_all=1
  [ "$rc_all" = 0 ] && run_bench "$OUT/ooo_snoop_filter/osf_tb" 'RTL_REVIEW_PASS' +oracle_negative ''
fi

# ---- tb_g6lc_snoop_filter : in-order snoop filter --------------------------
if [ "$BENCH" = all ] || [ "$BENCH" = snoop_filter ]; then
  build snoop_filter tb_g6lc_snoop_filter sf_tb \
    "$ROOT/core/include/config_pkg.sv" \
    "$R/coherence/g6lc_coherence_pkg.sv" \
    "$R/coherence/g6lc_snoop_filter.sv" \
    "$ROOT/verif/tb/uncore/tb_g6lc_snoop_filter.sv" || rc_all=1
  [ "$rc_all" = 0 ] && run_bench "$OUT/snoop_filter/sf_tb" 'RTL_REVIEW_PASS' +oracle_negative 0 1 2 3 4 5 6
fi

# ---- tb_g6lc_axi_2to1_mux : core/Ara AXI response-ownership mux -------------
if [ "$BENCH" = all ] || [ "$BENCH" = axi_2to1_mux ]; then
  build axi_2to1_mux tb_g6lc_axi_2to1_mux mux_tb \
    "$T" \
    "$ROOT/vendor/pulp-platform/axi/src/axi_pkg.sv" \
    "$R/src/g6lc_axi_2to1_mux.sv" \
    "$ROOT/verif/tb/uncore/tb_g6lc_axi_2to1_mux.sv" || rc_all=1
  [ "$rc_all" = 0 ] && run_bench "$OUT/axi_2to1_mux/mux_tb" 'RTL_REVIEW_PASS' +oracle_negative 0 1 2
fi

exit $rc_all
