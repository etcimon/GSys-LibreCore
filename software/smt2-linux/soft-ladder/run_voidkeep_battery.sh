#!/bin/bash
# SPDX-License-Identifier: MIT
# VOID-keep 0x80040xxx: minis then pin 400k + hold 400k.
set -euo pipefail
. /opt/testharness/env.sh
ROOT=/opt/testharness/repo
H=/opt/testharness/work/work-ver-smt2-fw64-B/Variane_testharness
MINI=/opt/testharness/repo/software/smt2-linux/soft-ladder/_mini_out
OUT=/opt/testharness/runs/b1-voidkeep40
mkdir -p "$OUT"
export CVA6_TRAP_DUMP=1 CVA6_SOAK_EXIT=1 CVA6_COOKIE_EXIT=1 CVA6_WFI_EXIT=0
echo "harness $(md5sum "$H")"

run_mini() {
  local elf="$1" tag="$2"
  echo "=== mini ${tag} ==="
  set +e
  "$H" +time_out=40000 +max-cycles=40000 +debug_disable +quiet_axi \
    +tohost_addr=0x80001000 "$elf" >"$OUT/${tag}.log" 2>&1
  echo "rc=$?"
  set -e
  grep -E "SUCCESS|FAILED|tohost|hangpc|rvfi|Simulation terminated" "$OUT/${tag}.log" | tail -6
}

find_elf() {
  local n="$1"
  if [[ -f "$MINI/$n" ]]; then echo "$MINI/$n"; return; fi
  if [[ -f "/opt/testharness/runs/b1-ecall-minis/$n" ]]; then echo "/opt/testharness/runs/b1-ecall-minis/$n"; return; fi
  find /opt/testharness/runs -name "$n" -type f 2>/dev/null | head -1
}
run_mini "$(find_elf mini_ecall_list_init.elf)" init
run_mini "$(find_elf mini_ecall_list_one.elf)" one
run_mini "$(find_elf mini_ecall_list_walk.elf)" walk
run_mini "$(find_elf mini_ecall_list_void.elf)" void
run_mini "$(find_elf mini_fdt_nt_osbi_tight.elf)" tight
run_mini "$(find_elf mini_fdt_nt_osbi_h0.elf)" h0
run_mini "$(find_elf mini_fdt_nt_osbi_sw.elf)" sw

run_soak() {
  local elf="$1" tag="$2" to="$3"
  echo "=== soak ${tag} to=${to} ==="
  set +e
  CVA6_TRAP_DUMP=1 CVA6_SOAK_EXIT=1 CVA6_COOKIE_EXIT=1 CVA6_WFI_EXIT=0 \
    "$H" +time_out="$to" +max-cycles="$to" +debug_disable +quiet_axi \
    +tohost_addr=0x80041730 "$elf" >"$OUT/${tag}.log" 2>&1
  echo "rc=$?"
  set -e
  grep -E "SUCCESS|FAILED|tohost|hangpc|cookie|CLASSIFY|51b1|plat_hc|Simulation terminated" \
    "$OUT/${tag}.log" | tail -12
}

PIN="$ROOT/software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf"
HOLD="$ROOT/software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.held.elf"
run_soak "$PIN" pin400k 400000
run_soak "$HOLD" hold400k 400000
echo DONE
