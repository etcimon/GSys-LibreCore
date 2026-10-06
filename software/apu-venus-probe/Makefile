# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Bare-metal Venus probe image for tb_g6lc_apu_cva6_venus.  Builds
# venus_probe.{elf,bin,hex} at DRAM base 0x80020000 (queues/cookie live
# below it; see link.ld) plus the generated venus_map.h / vn_map.svh /
# tape.h consumed by both the C and the testbench.

RISCV   ?= riscv64-unknown-elf-
CC      := $(RISCV)gcc
OBJCOPY := $(RISCV)objcopy
SIZE    := $(RISCV)size

TARGET_CFG ?= g6lc64_stream8
CFG_PKG    := ../../core/include/$(TARGET_CFG)_config_pkg.sv

CFLAGS  := -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany \
           -O2 -ffreestanding -nostdlib -fno-builtin -Wall \
           -fno-stack-protector
LDFLAGS := -nostdlib -T link.ld

TAPES := ue_sm5_transport ue_cpos_bufcopy_1

all: venus_probe.hex

venus_map.h vn_map.svh: tools/gen_venus_map.py ../../corev_apu/include/g6lc_apu_cfg_pkg.sv ../../corev_apu/apu/include/g6lc_apu_pkg.sv $(CFG_PKG)
	python3 tools/gen_venus_map.py venus_map.h vn_map.svh $(CFG_PKG)

tape.h: tools/tape2c.py
	python3 tools/tape2c.py tape.h $(TAPES)

crt0.o: crt0.S
	$(CC) $(CFLAGS) -c $< -o $@

venus_probe.o: venus_probe.c virtio_mmio.h venus_map.h tape.h
	$(CC) $(CFLAGS) -c $< -o $@

venus_probe.elf: crt0.o venus_probe.o link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) crt0.o venus_probe.o -o $@
	$(SIZE) $@

venus_probe.bin: venus_probe.elf
	$(OBJCOPY) -O binary $< $@

venus_probe.hex: venus_probe.bin tools/bin2hex.py
	python3 tools/bin2hex.py $< $@

clean:
	rm -f *.o *.elf *.bin *.hex venus_map.h vn_map.svh tape.h

.PHONY: all clean
