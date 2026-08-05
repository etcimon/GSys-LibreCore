# SPDX-License-Identifier: MIT
# Dual-hart S-mode payload for CVA6 SMT2 OpenSBI.
#
#   make CROSS_COMPILE=riscv64-unknown-elf-
#   make CROSS_COMPILE=riscv-none-elf-

CROSS_COMPILE ?= riscv64-unknown-elf-
CC      := $(CROSS_COMPILE)gcc
OBJCOPY := $(CROSS_COMPILE)objcopy

CFLAGS  := -march=rv64imac_zicsr -mabi=lp64 -mcmodel=medany \
           -nostdlib -ffreestanding -fno-builtin -O2 -Wall
LDFLAGS := -T link.ld -nostdlib -static

.PHONY: all clean
all: smt2_sbi_dual.elf smt2_sbi_dual.bin

smt2_sbi_dual.elf: smt2_sbi_dual.S link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ smt2_sbi_dual.S

smt2_sbi_dual.bin: smt2_sbi_dual.elf
	$(OBJCOPY) -O binary $< $@

clean:
	-rm -f smt2_sbi_dual.elf smt2_sbi_dual.bin smt2_sbi_dual.o 2>/dev/null; \
	-del /Q smt2_sbi_dual.elf smt2_sbi_dual.bin smt2_sbi_dual.o 2>NUL; true
