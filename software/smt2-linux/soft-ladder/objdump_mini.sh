#!/bin/bash
set -uo pipefail
export PATH="/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:${PATH}"
ROOT=/mnt/e/cva6
COMMON="$ROOT/verif/tests/custom/common"
ELF=/tmp/cva6-mini-od.elf
riscv-none-elf-gcc -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
  -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
  "$ROOT/verif/tests/custom/multicore/mini_fdt_a0_is_fdt.S" \
  -T "$COMMON/link_verilator.ld" -o "$ELF" \
  -march=rv64imafdc_zicsr_zifencei -mabi=lp64d
riscv-none-elf-objdump -d "$ELF" | awk '/<offset_ptr_raw>:/,/<fail_from_a0>:/'
