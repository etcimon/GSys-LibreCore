#!/bin/bash
export PATH="/opt/xpack/xpack-riscv-none-elf-gcc-14.2.0-3/bin:${PATH}"
ROOT=/mnt/e/cva6
COMMON="$ROOT/verif/tests/custom/common"
ELF=/tmp/cva6-mini-od2.elf
riscv-none-elf-gcc -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
  -I"$ROOT/verif/tests/custom/env" -I"$COMMON" \
  "$ROOT/verif/tests/custom/multicore/mini_fdt_a0_is_fdt.S" \
  -T "$COMMON/link_verilator.ld" -o "$ELF" \
  -march=rv64imafdc_zicsr_zifencei -mabi=lp64d
riscv-none-elf-objdump -d "$ELF" | awk '/<trap>:/,/fdt_blob/'
echo '---- tohost ----'
riscv-none-elf-nm "$ELF" | awk '$3=="tohost"||$3=="_start"||$3=="trap"'
