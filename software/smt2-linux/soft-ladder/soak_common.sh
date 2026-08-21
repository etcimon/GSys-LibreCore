#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Generic OpenSBI soak for slfix. Source from soak_<id>.sh then call
# soft_ladder_soak_main. There is no testharness checkpoint/resume —
# SUCCESS is cookie 51b1babe. g6lc_tb.cpp CVA6_SOAK_EXIT stops hold/nat
# at the cookie, peel at the known pin (or dual-WFI). Optional
# CVA6_TRACE / CVA6_TRACE_SPEC / CVA6_TRACE_FILE for localization.
#
# Env:
#   SOAK_WHAT      hold,nat,peel or all (default all)
#   SOAK_PARALLEL  1 (default) run selected ELFs together
#   SOAK_CYCLES    fallback +max-cycles (default 6000000)
#   SOAK_HARNESS   testharness path
#   SOAK_OUT       log dir
#   CVA6_COOKIE_EXIT  default 1 (set 0 to disable)
#   CVA6_SOAK_EXIT    default 1 — cookie + pin + dual-WFI
#   CVA6_PIN_MEPC / CVA6_PIN_MCAUSE  peel pin (default 0x800129f8 / 4)
#   CVA6_TRACE / CVA6_TRACE_SPEC / CVA6_TRACE_FILE  optional localization
#   HELD / PIN / PEEL  ELF paths (defaults under this dir/build/)
#
set -uo pipefail
_SOAK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SOAK_HARNESS:=${SOFT_LADDER_HARNESS:+$CVA6_REPO_DIR/$SOFT_LADDER_HARNESS/Variane_testharness}}"
: "${SOAK_HARNESS:=${CVA6_REPO_DIR:-/mnt/e/cva6}/work-ver-smt2-slfix/Variane_testharness}"
: "${SOAK_OUT:=/tmp/cva6-soft-ladder-soak}"
: "${SOAK_WHAT:=all}"
: "${SOAK_PARALLEL:=1}"
: "${SOAK_CYCLES:=6000000}"
: "${SOAK_TOHOST:=0x80041730}"
: "${PIN:=$_SOAK_DIR/build/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf}"
: "${PEEL:=$_SOAK_DIR/build/fw_payload_r3a_c15_plat_skip.peel-getprop.elf}"
: "${HELD:=$_SOAK_DIR/build/fw_payload_r3a_c15_plat_skip.held-nobyoff.elf}"
if [[ ! -f "$HELD" ]]; then
  HELD="$_SOAK_DIR/build/fw_payload_r3a_c15_plat_skip.held.elf"
fi
mkdir -p "$SOAK_OUT"
export CVA6_TRAP_DUMP=1
if [[ "${CVA6_COOKIE_EXIT:-1}" == "0" ]]; then
  unset CVA6_COOKIE_EXIT
else
  export CVA6_COOKIE_EXIT=1
fi
if [[ "${CVA6_SOAK_EXIT:-1}" == "0" ]]; then
  unset CVA6_SOAK_EXIT
else
  export CVA6_SOAK_EXIT=1
fi
: "${CVA6_PIN_MEPC:=0x800129f8}"
: "${CVA6_PIN_MCAUSE:=4}"
export CVA6_PIN_MEPC CVA6_PIN_MCAUSE

soft_ladder_soak_run() {
  local tag="$1" elf="$2"
  echo "=== $tag $(date +%H:%M:%S) ==="
  if [[ ! -f "$elf" ]]; then
    echo "CLASSIFY=FAIL $tag missing $elf"
    return 1
  fi
  set +e
  "$SOAK_HARNESS" +time_out="$SOAK_CYCLES" +max-cycles="$SOAK_CYCLES" \
    +debug_disable +quiet_axi +tohost_addr="$SOAK_TOHOST" \
    "$elf" >"$SOAK_OUT/veri_$tag.log" 2>&1
  local rc=$?
  set -e
  if grep -qE '\[cookie-exit\]|\[1000\]=(0x)?[0-9a-fA-F]*51b1babe' "$SOAK_OUT/veri_$tag.log"; then
    echo "CLASSIFY=SUCCESS $tag rc=$rc"
  else
    echo "CLASSIFY=FAIL $tag rc=$rc"
  fi
  grep -E '\[cookie-exit\]|\[pin-exit\]|\[wfi-exit\]|\[npc-exit\]|\[trace\]|SUCCESS|FAILED|\[1000\]|\[1008\]|\[hangpc\]|\[trapdump\]|BANR|plat_hc|BuildID|129f8' \
    "$SOAK_OUT/veri_$tag.log" | tail -16 || true
  echo
}

soft_ladder_soak_wanted() {
  local tag="$1"
  case ",$SOAK_WHAT," in
    *,all,*|*,"$tag",*) return 0 ;;
    *) return 1 ;;
  esac
}

soft_ladder_soak_main() {
  echo "harness $(md5sum "$SOAK_HARNESS")"
  file "$SOAK_HARNESS"
  echo "pin $(md5sum "$PIN" 2>/dev/null || echo missing)"
  echo "peel $(md5sum "$PEEL" 2>/dev/null || echo missing)"
  echo "held $(md5sum "$HELD" 2>/dev/null || echo missing)"
  echo "SOAK_WHAT=$SOAK_WHAT SOAK_PARALLEL=$SOAK_PARALLEL CVA6_COOKIE_EXIT=${CVA6_COOKIE_EXIT:-}"
  local pids=() tags=()
  _launch() {
    local tag="$1" elf="$2"
    if ! soft_ladder_soak_wanted "$tag"; then
      return 0
    fi
    if [[ "$SOAK_PARALLEL" == "1" ]]; then
      soft_ladder_soak_run "$tag" "$elf" &
      pids+=("$!")
      tags+=("$tag")
    else
      soft_ladder_soak_run "$tag" "$elf"
    fi
  }
  _launch hold "$HELD"
  _launch nat "$PIN"
  _launch peel "$PEEL"
  if [[ "$SOAK_PARALLEL" == "1" && ${#pids[@]} -gt 0 ]]; then
    local i
    for i in "${!pids[@]}"; do
      wait "${pids[$i]}" || true
    done
  fi
  echo DONE
}
