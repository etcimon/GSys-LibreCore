#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
. /opt/testharness/env.sh
ROOT=/opt/testharness/repo
OUT=/opt/testharness/runs/b1-ecall-minis
H=/opt/testharness/work/work-ver-smt2-fw64-B/Variane_testharness
GCC=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc
NM=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-nm
LD="$ROOT/verif/tests/custom/common/link_verilator.ld"
COMMON="$ROOT/verif/tests/custom/common"
mkdir -p "$OUT"
export CVA6_TRAP_DUMP=1 CVA6_SOAK_EXIT=1 CVA6_COOKIE_EXIT=0 CVA6_WFI_EXIT=0
compile() {
  local src="$1" stem="$2"
  "$GCC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
    "$src" -T "$LD" -o "$OUT/${stem}.elf" \
    -march=rv64imafdc_zicsr_zifencei -mabi=lp64d
  echo "=== compile ${stem} ==="
  md5sum "$OUT/${stem}.elf"
  "$NM" "$OUT/${stem}.elf" | awk '$3=="tohost" || $3=="_start"'
}
run_one() {
  local stem="$1"
  echo "=== run ${stem} ==="
  set +e
  "$H" +time_out=40000 +max-cycles=40000 +debug_disable +quiet_axi \
    +tohost_addr=0x80001000 "$OUT/${stem}.elf" >"$OUT/${stem}.log" 2>&1
  echo "rc=$?"
  set -e
  grep -E "SUCCESS|FAILED|tohost|hangpc|rvfi|Simulation terminated" "$OUT/${stem}.log" | tail -8
}
compile "$ROOT/verif/tests/custom/multicore/mini_ecall_list_init.S" mini_ecall_list_init
compile "$ROOT/verif/tests/custom/multicore/mini_ecall_list_one.S" mini_ecall_list_one
compile "$ROOT/verif/tests/custom/multicore/mini_ecall_list_walk.S" mini_ecall_list_walk
compile "$ROOT/verif/tests/custom/multicore/mini_ecall_list_void.S" mini_ecall_list_void
run_one mini_ecall_list_init
run_one mini_ecall_list_one
run_one mini_ecall_list_walk
run_one mini_ecall_list_void
echo DONE
