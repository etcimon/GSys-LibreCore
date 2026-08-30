#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
. /opt/testharness/env.sh
H=/opt/testharness/work/work-ver-smt2-fw64-B/Variane_testharness
OUT=/opt/testharness/runs/b1-voidkeep40
ROOT=/opt/testharness/repo
mkdir -p "$OUT"
export CVA6_TRAP_DUMP=1 CVA6_SOAK_EXIT=1 CVA6_COOKIE_EXIT=1 CVA6_WFI_EXIT=0

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

run_soak() {
  local elf="$1" tag="$2" to="$3"
  echo "=== soak ${tag} to=${to} ==="
  set +e
  "$H" +time_out="$to" +max-cycles="$to" +debug_disable +quiet_axi \
    +tohost_addr=0x80041730 "$elf" >"$OUT/${tag}.log" 2>&1
  echo "rc=$?"
  set -e
  grep -E "SUCCESS|FAILED|tohost|hangpc|cookie|CLASSIFY|51b1|plat_hc|Simulation terminated" \
    "$OUT/${tag}.log" | tail -12
}

run_mini /opt/testharness/runs/b1-nt-nl-h0-addi-nackinv/mini_fdt_nt_osbi_h0.elf h0addi
run_mini /opt/testharness/runs/b1-nt-nl-sw-ackinv-rev/mini_fdt_nt_osbi_sw.elf sw
run_soak "$ROOT/software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf" pin400k 400000
run_soak "$ROOT/software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.held.elf" hold400k 400000
echo DONE
