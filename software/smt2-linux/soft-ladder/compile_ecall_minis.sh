#!/bin/bash
# SPDX-License-Identifier: MIT
set -euo pipefail
. /opt/testharness/env.sh
ROOT=/opt/testharness/repo
OUT=/opt/testharness/runs/b1-ecall-minis
GCC=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc
NM=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-nm
OBJDUMP=/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-objdump
LD="$ROOT/verif/tests/custom/common/link_verilator.ld"
COMMON="$ROOT/verif/tests/custom/common"
mkdir -p "$OUT"
compile() {
  local src="$1" stem="$2"
  "$GCC" -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
    -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
    "$src" -T "$LD" -o "$OUT/${stem}.elf" \
    -march=rv64imafdc_zicsr_zifencei -mabi=lp64d
  echo "=== ${stem} ==="
  md5sum "$OUT/${stem}.elf"
  "$NM" "$OUT/${stem}.elf" | awk '$3=="tohost" || $3=="_start" || $3=="sentinel" || $3=="node0"'
}
compile "$ROOT/verif/tests/custom/multicore/mini_ecall_list_init.S" mini_ecall_list_init
compile "$ROOT/verif/tests/custom/multicore/mini_ecall_list_one.S" mini_ecall_list_one
compile "$ROOT/verif/tests/custom/multicore/mini_ecall_list_walk.S" mini_ecall_list_walk
echo "=== existing unroll tohost ==="
UNROLL=/opt/testharness/runs/b1-ecall-unroll/mini_ecall_list_walk.elf
if [[ -f "$UNROLL" ]]; then
  "$NM" "$UNROLL" | awk '$3=="tohost" || $3=="_start" || $3=="sentinel"'
  "$OBJDUMP" -d "$UNROLL" | head -n 80
fi
echo "=== held 8d8e window ==="
HELD=/opt/testharness/repo/software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.held.elf
"$OBJDUMP" -d "$HELD" --start-address=0x80008d6c --stop-address=0x80008dc8
echo DONE
