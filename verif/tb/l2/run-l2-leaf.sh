#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Standalone leaf testbenches for the small self-contained L2/coherence/l3
# leaf modules that previously only ran through the remote review harnesses:
#   tb_g6lc_inval_bus      — g6lc_inval_bus broadcast/admission/departure
#   tb_g6lc_l2_tag_miter   — flop-vs-SRAM g6lc_l2_tag equivalence miter
#   tb_g6lc_pf             — g6lc_server_prefetcher response-ownership contract
# (tb_g6lc_coherence_hub and tb_g6lc_cmo_engine have their own runners.)
#
#   bash verif/tb/l2/run-l2-leaf.sh                 # all benches
#   LEAF_BENCH=inval_bus bash verif/tb/l2/run-l2-leaf.sh
#   LEAF_BENCH=tag_miter LEAF_TAG_WU=1 bash ...     # WRITE_UPDATE=1 miter arm
#   LEAF_BENCH=pf bash ...
#
# Knobs (env):
#   LEAF_OUT=<dir>      output dir (default /tmp/g6lc-l2-leaf)
#   LEAF_BENCH=all|inval_bus|tag_miter|pf
#   LEAF_TAG_WU=0|1     g6lc_l2_tag WRITE_UPDATE arm for the miter (default 0)
#   LEAF_NEGATIVE=0|1   also run each scenario/bench negative control (default 0)
#   LEAF_RTL=<repo-rel> RTL root holding coherence/l2_cache/l3_cache
#                       (default corev_apu; hyp8 redesign is
#                       build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LEAF_RTL="${LEAF_RTL:-corev_apu}"
[[ "$LEAF_RTL" =~ ^[A-Za-z0-9_./-]+$ && "$LEAF_RTL" != *..* ]] || { echo "[l2-leaf] bad LEAF_RTL" >&2; exit 2; }
OUT="${LEAF_OUT:-/tmp/g6lc-l2-leaf}"
mkdir -p "$OUT"
BENCH="${LEAF_BENCH:-all}"
case "$BENCH" in all|inval_bus|tag_miter|pf) ;; *) echo "[l2-leaf] bad LEAF_BENCH=$BENCH" >&2; exit 2;; esac
NEG="${LEAF_NEGATIVE:-0}"

VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1; then
  for c in /root/tools/verilator-v5.008/bin/verilator \
           /opt/testharness/toolchains/verilator-v5.008/bin/verilator \
           "$ROOT/build-platform/workspace/tooling/linux-eda-suite/bin/verilator_bin"; do
    [ -x "$c" ] && VERILATOR="$c" && break
  done
fi
command -v "$VERILATOR" >/dev/null 2>&1 || { echo "[l2-leaf] no verilator" >&2; exit 2; }
"$VERILATOR" --version
ulimit -c 0

R="$ROOT/$LEAF_RTL"
VL_WARN=(-Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK \
         -Wno-LATCH -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-UNSIGNED \
         -Wno-DECLFILENAME)

# Extract g6lc_l2_tb_pkg (AXI channel/transaction types) from the L2 leaf bench,
# the same way run-coherence-hub.sh / run_inval_review.py do.
T="$OUT/types.sv"
sed -n '/^package g6lc_l2_tb_pkg;/,/^endpackage/p' \
  "$ROOT/verif/tb/l2/tb_g6lc_l2.sv" > "$T"
grep -q 'endpackage' "$T" || { echo "[l2-leaf] g6lc_l2_tb_pkg extraction failed" >&2; exit 2; }

build() { # $1=name $2=top $3=outfile $4...=sources
  local name="$1" top="$2" out="$3"; shift 3
  local mdir="$OUT/$name"
  mkdir -p "$mdir"
  "$VERILATOR" --binary --timing "${VL_WARN[@]}" "$@" \
    --top-module "$top" -Mdir "$mdir" -o "$out" \
    > "$mdir/build.log" 2>&1 || {
      echo "[l2-leaf] $name BUILD FAILED"; tail -n 40 "$mdir/build.log"; return 1; }
  echo "[l2-leaf] $name build ok"
}

rc_all=0

run_scen() { # $1=binary $2=pass-regex $3=scenarios...  ; extra args after --
  local bin="$1" passre="$2"; shift 2
  local scens=("$@")
  for s in "${scens[@]}"; do
    for neg in 0 1; do
      [ "$neg" = 1 ] && [ "$NEG" != 1 ] && continue
      local args=(+scenario="$s") log="$OUT/$(basename "$bin")-s$s-neg$neg.log"
      [ "$neg" = 1 ] && args+=(+oracle_negative)
      set +e; "$bin" "${args[@]}" > "$log" 2>&1; local rc=$?; set -e
      if [ "$neg" = 0 ]; then
        # Positive arm: the bench must reach its PASS marker.
        if grep -qE "$passre" "$log"; then
          echo "[l2-leaf] PASS $s neg=0"
        else
          echo "[l2-leaf] FAIL $s neg=0 rc=$rc"; grep -iE "fatal|assert|error" "$log" | head -3
          rc_all=1
        fi
      else
        # Negative arm: the injected fault must be caught — the sim aborts
        # with a Fatal/assertion rather than reaching the PASS marker.
        if grep -qE "$passre" "$log"; then
          echo "[l2-leaf] FAIL $s neg=1 (passed despite fault — control broken)"
          rc_all=1
        elif grep -qiE "%fatal|assertion failed|%error|%stop" "$log"; then
          echo "[l2-leaf] PASS $s neg=1 (fault detected)"
        else
          echo "[l2-leaf] FAIL $s neg=1 rc=$rc (no detection, no pass)"
          grep -iE "fatal|assert|error" "$log" | head -3; rc_all=1
        fi
      fi
    done
  done
}

# ---- tb_g6lc_inval_bus : g6lc_inval_bus broadcast/admission/departure ------
if [ "$BENCH" = all ] || [ "$BENCH" = inval_bus ]; then
  build inval_bus tb_g6lc_inval_bus ib_tb \
    "$R/coherence/g6lc_coherence_pkg.sv" \
    "$R/coherence/g6lc_inval_bus.sv" \
    "$ROOT/verif/tb/l2/tb_g6lc_inval_bus.sv" || rc_all=1
  [ "$rc_all" = 0 ] && run_scen "$OUT/inval_bus/ib_tb" 'INVBUS_PASS' 0 1 2 3
fi

# ---- tb_g6lc_l2_tag_miter : flop-vs-SRAM tag equivalence --------------------
if [ "$BENCH" = all ] || [ "$BENCH" = tag_miter ]; then
  wu="${LEAF_TAG_WU:-0}"
  build tag_miter tb_g6lc_l2_tag_miter mit_tb \
    -GWRITE_UPDATE="$wu" \
    "$ROOT/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
    "$R/l2_cache/g6lc_l2_tag.sv" \
    "$ROOT/verif/tb/l2/tb_g6lc_l2_tag_miter.sv" || rc_all=1
  if [ "$rc_all" = 0 ]; then
    for neg in 0 1; do
      [ "$neg" = 1 ] && [ "$NEG" != 1 ] && continue
      margs=(); [ "$neg" = 1 ] && margs+=(+miter_negative)
      log="$OUT/tag_miter-s0-neg$neg.log"
      set +e; "$OUT/tag_miter/mit_tb" "${margs[@]}" > "$log" 2>&1; mrc=$?; set -e
      if [ "$neg" = 0 ]; then
        if grep -q 'L2TAG_MITER_PASS' "$log"; then
          echo "[l2-leaf] PASS tag_miter wu=$wu neg=0"
        else
          echo "[l2-leaf] FAIL tag_miter wu=$wu neg=0 rc=$mrc"
          grep -iE "fatal|assert|error" "$log" | head -3; rc_all=1
        fi
      else
        if grep -q 'L2TAG_MITER_PASS' "$log"; then
          echo "[l2-leaf] FAIL tag_miter wu=$wu neg=1 (passed despite fault)"
          rc_all=1
        elif grep -qiE "%fatal|assertion failed|%error|%stop" "$log"; then
          echo "[l2-leaf] PASS tag_miter wu=$wu neg=1 (fault detected)"
        else
          echo "[l2-leaf] FAIL tag_miter wu=$wu neg=1 rc=$mrc (no detection)"
          grep -iE "fatal|assert|error" "$log" | head -3; rc_all=1
        fi
      fi
    done
  fi
fi

# ---- tb_g6lc_pf : g6lc_server_prefetcher response-ownership -----------------
if [ "$BENCH" = all ] || [ "$BENCH" = pf ]; then
  build pf tb_g6lc_pf pf_tb \
    "$T" \
    "$ROOT/vendor/pulp-platform/axi/src/axi_pkg.sv" \
    "$R/l3_cache/g6lc_server_prefetcher.sv" \
    "$ROOT/verif/tb/l2/tb_g6lc_pf.sv" || rc_all=1
  [ "$rc_all" = 0 ] && run_scen "$OUT/pf/pf_tb" 'RTL_REVIEW_PASS' 0 1 2 3
fi

exit $rc_all
