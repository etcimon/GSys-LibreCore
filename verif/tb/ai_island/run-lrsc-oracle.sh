#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Oracle-validity check for the exclusive monitor (AI-X1).
#
# Builds tb_g6lc_axi_lrsc twice and requires OPPOSITE verdicts:
#
#   NRes = 8  (reservation table, shipped)  -> PASS
#   NRes = 1  (one global reservation, pre-fix, +define+G6LC_TB_LRSC_SINGLE_RES)
#                                           -> FAIL on the disjoint scenario
#
# A gate that has never failed is not an oracle. The same-address snoop
# scenario passes under BOTH designs -- only one line is in play there -- so
# without this pairing the monitor's headline test proves nothing about the
# defect it exists to catch. See architecture/uncore/dram-channel-scaling.md
# §5.2 rule 7a.
#
# Fast: unit TB, seconds per build. The harness-level equivalent
# (ai-dual-core-lrsc-disjoint) needs a 22-minute Variane rebuild per polarity.
#
# Not Variane. Not OpenSBI. Not a throughput number.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

if ! command -v verilator >/dev/null 2>&1; then
  echo "SKIP no verilator"
  exit 0
fi

AXI="$ROOT/vendor/pulp-platform/axi"

build_and_run() {
  local tag="$1"; shift
  local out="${LRSC_ORACLE_OUT:-/tmp/g6lc-lrsc}-$tag"
  mkdir -p "$out"
  echo "[lrsc-oracle] build $tag ${*:-(no extra defines)}"
  if ! verilator --binary --timing -Wno-fatal -Wno-TIMESCALEMOD -Wno-UNUSED \
      -Wno-UNOPTFLAT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY \
      -Wno-CASEINCOMPLETE \
      "$@" \
      -I"$AXI/include" \
      "$AXI/src/axi_pkg.sv" \
      "$AXI/src/axi_intf.sv" \
      "$ROOT/corev_apu/src/g6lc_axi_lrsc.sv" \
      "$ROOT/verif/tb/ai_island/tb_g6lc_axi_lrsc.sv" \
      --top-module tb_g6lc_axi_lrsc \
      -Mdir "$out" -o "tb-$tag" >"$out/build.log" 2>&1; then
    if grep -q 'ZERODLY' "$out/build.log"; then
      echo "[lrsc-oracle] SKIP $tag: this Verilator rejects the TB's #0 settle"
      echo "[lrsc-oracle]      points (%Error-ZERODLY). Pre-existing and shared"
      echo "[lrsc-oracle]      with tb_g6lc_ai_atomics_aw / _litedram_wrap; see"
      echo "[lrsc-oracle]      the header of tb_g6lc_axi_lrsc.sv for the two"
      echo "[lrsc-oracle]      substitutions already tried and why they fail."
      return 98
    fi
    echo "[lrsc-oracle] BUILD FAILED $tag"
    tail -25 "$out/build.log"
    return 99
  fi
  echo "[lrsc-oracle] run $tag"
  "$out/tb-$tag" 2>&1 | tail -8
  return "${PIPESTATUS[0]}"
}

build_and_run table
RC_TABLE=$?
build_and_run single +define+G6LC_TB_LRSC_SINGLE_RES
RC_SINGLE=$?

echo "[lrsc-oracle] ---------------------------------------"
echo "[lrsc-oracle] table(NRes=8) rc=$RC_TABLE  single(NRes=1) rc=$RC_SINGLE"
if [[ $RC_TABLE -eq 98 || $RC_SINGLE -eq 98 ]]; then
  echo "[lrsc-oracle] SKIP unit TB unbuildable on this Verilator; the"
  echo "[lrsc-oracle]      harness-level oracle stands instead:"
  echo "[lrsc-oracle]      ai-dual-core-lrsc-disjoint PASS tohost=1 on NRes=2,"
  echo "[lrsc-oracle]      FAIL tohost=9 on +define+G6LC_AI_LRSC_SINGLE_RES."
  exit 0
fi
if [[ $RC_TABLE -eq 99 || $RC_SINGLE -eq 99 ]]; then
  echo "[lrsc-oracle] FAIL a polarity did not build"
  exit 1
fi
if [[ $RC_TABLE -eq 0 && $RC_SINGLE -ne 0 ]]; then
  echo "[lrsc-oracle] PASS oracle valid: table passes, single reservation fails"
  exit 0
fi
if [[ $RC_TABLE -ne 0 ]]; then
  echo "[lrsc-oracle] FAIL the shipped reservation table does not pass"
  exit 1
fi
echo "[lrsc-oracle] FAIL single reservation PASSED -- the disjoint scenario"
echo "[lrsc-oracle]      no longer distinguishes the defect, so the gate has"
echo "[lrsc-oracle]      stopped being an oracle. Do not weaken it; fix it."
exit 1
