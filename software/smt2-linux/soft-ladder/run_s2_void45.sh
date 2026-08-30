#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
. /opt/testharness/env.sh
H=/opt/testharness/work/work-ver-smt2-fw64-B/Variane_testharness
ROOT=/opt/testharness/repo
OUT=/opt/testharness/runs/b1-void45
GCC=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc
LD="$ROOT/verif/tests/custom/common/link_verilator.ld"
mkdir -p "$OUT"
export CVA6_TRAP_DUMP=1 CVA6_SOAK_EXIT=1 CVA6_COOKIE_EXIT=1 CVA6_WFI_EXIT=0
echo "harness $(md5sum "$H")"

"$GCC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
  -I"$ROOT/verif/tests/custom/env" -I"$ROOT/verif/tests/custom/common" \
  "$ROOT/verif/tests/custom/multicore/mini_printf_la_lock.S" -T "$LD" \
  -o "$OUT/mini_printf_la_lock.elf" -march=rv64imafdc_zicsr_zifencei -mabi=lp64d

run_mini() {
  local elf="$1" tag="$2"
  echo "=== mini ${tag} ==="
  set +e
  "$H" +time_out=40000 +max-cycles=40000 +debug_disable +quiet_axi \
    +tohost_addr=0x80001000 "$elf" >"$OUT/${tag}.log" 2>&1
  echo "rc=$?"
  set -e
  grep -E "SUCCESS|FAILED|hangpc|rvfi|Simulation terminated" "$OUT/${tag}.log" | tail -5
}

run_soak() {
  local elf="$1" tag="$2"
  echo "=== soak ${tag} ==="
  set +e
  "$H" +time_out=400000 +max-cycles=400000 +debug_disable +quiet_axi \
    +tohost_addr=0x80041730 "$elf" >"$OUT/${tag}.log" 2>&1
  echo "rc=$?"
  set -e
  grep -E "cookie-exit|51b1|plat_hc|hangpc|SUCCESS|FAILED" "$OUT/${tag}.log" | tail -8
}

run_mini "$OUT/mini_printf_la_lock.elf" lalock
run_mini /opt/testharness/runs/b1-nt-nl-h0-addi-nackinv/mini_fdt_nt_osbi_h0.elf h0
run_mini /opt/testharness/runs/b1-tight-void40/mini_fdt_nt_osbi_tight.elf tight
run_soak "$ROOT/software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf" pin
run_soak "$ROOT/software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.held.elf" hold
# peel-printf ELF is local-only; skip if missing on remote
if [[ -f /opt/testharness/runs/s2-hold-peel-printf/data/fw_payload_r3a_c15_plat_skip.held.peel-printf.elf ]]; then
  run_soak /opt/testharness/runs/s2-hold-peel-printf/data/fw_payload_r3a_c15_plat_skip.held.peel-printf.elf holdprintf
fi
if [[ -f /opt/testharness/runs/s2-peel-printf/data/fw_payload_r3a_c15_plat_skip.peel-printf.elf ]]; then
  run_soak /opt/testharness/runs/s2-peel-printf/data/fw_payload_r3a_c15_plat_skip.peel-printf.elf pinprintf
fi
echo DONE
