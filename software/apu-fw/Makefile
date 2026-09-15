# SPDX-License-Identifier: MIT
# Resident APU firmware for hart 1. Does not patch SMT OpenSBI.

CROSS_COMPILE ?= riscv64-unknown-elf-
CC      := $(CROSS_COMPILE)gcc
HOSTCC  ?= gcc
OBJCOPY := $(CROSS_COMPILE)objcopy

CFLAGS  := -march=rv64i_zicsr -mabi=lp64 -mcmodel=medany \
           -nostdlib -ffreestanding -fno-builtin -O2 -Wall \
           -Iinclude
LDFLAGS := -T link.ld -nostdlib -static

HEX  ?= ../../verif/tb/apu/apu_fw.hex
ELF  ?= apu_fw.elf
DTSI ?= ../../corev_apu/bootrom/g6lc-apu-domain.dtsi

.PHONY: all firmware firmware-tgsi firmware-tgsi-cc enc-check tgsi-check tgsi-fw-check map-check boot-check load-check osbi-check clean
all: enc-check tgsi-check tgsi-fw-check map-check boot-check load-check osbi-check
firmware: apu_fw.elf apu_fw.bin
firmware-tgsi: apu_tgsi_fw.elf apu_tgsi_fw.bin ../../verif/tb/apu/apu_tgsi.hex
firmware-tgsi-cc: apu_tgsi_cc.elf apu_tgsi_cc.bin ../../verif/tb/apu/apu_tgsi_cc.hex

enc-check: test/enc_check.c include/g6lc_apu_exec.h
	$(HOSTCC) -Iinclude -o enc_check test/enc_check.c
	./enc_check

tgsi-check: test/tgsi_check.c src/g6lc_apu_tgsi.c include/g6lc_apu_tgsi.h include/g6lc_apu_exec.h
	$(HOSTCC) -Iinclude -o tgsi_check test/tgsi_check.c src/g6lc_apu_tgsi.c
	./tgsi_check

tgsi-fw-check: test/tgsi_fw_check.c src/g6lc_apu_tgsi.c src/g6lc_apu_tgsi_job.c \
		include/g6lc_apu_tgsi.h include/g6lc_apu_tgsi_job.h include/g6lc_apu_exec.h \
		include/g6lc_apu_mbox.h
	$(HOSTCC) -Iinclude -o tgsi_fw_check test/tgsi_fw_check.c \
		src/g6lc_apu_tgsi.c src/g6lc_apu_tgsi_job.c
	./tgsi_fw_check

map-check: test/map_check.c include/g6lc_apu_th_map.h
	$(HOSTCC) -Iinclude -o map_check test/map_check.c
	./map_check

boot-check: test/boot_check.c include/g6lc_apu_th_map.h
	$(HOSTCC) -Iinclude -o boot_check test/boot_check.c
	./boot_check "$(HEX)" "$(ELF)" "$(DTSI)"

load-check: test/load_check.c include/g6lc_apu_th_map.h
	$(HOSTCC) -Iinclude -o load_check test/load_check.c
	./load_check

osbi-check: test/osbi_check.c include/g6lc_apu_th_map.h
	$(HOSTCC) -Iinclude -o osbi_check test/osbi_check.c
	./osbi_check "../.."

apu_fw.elf: src/crt0.S src/apu_fw.c link.ld include/g6lc_apu_mbox.h include/g6lc_apu_exec.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ src/crt0.S src/apu_fw.c

apu_fw.bin: apu_fw.elf
	$(OBJCOPY) -O binary $< $@

apu_tgsi_fw.elf: src/crt0.S src/apu_tgsi_fw.c link.ld \
		include/g6lc_apu_mbox.h include/g6lc_apu_exec.h include/g6lc_apu_tgsi_job.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ src/crt0.S src/apu_tgsi_fw.c

apu_tgsi_fw.bin: apu_tgsi_fw.elf
	$(OBJCOPY) -O binary $< $@

../../verif/tb/apu/apu_tgsi.hex: apu_tgsi_fw.bin bin2hex.py
	python3 bin2hex.py apu_tgsi_fw.bin $@

apu_tgsi_cc.elf: src/crt0.S src/apu_tgsi_cc.c src/g6lc_apu_tgsi.c \
		src/g6lc_apu_tgsi_job.c link.ld include/g6lc_apu_mbox.h \
		include/g6lc_apu_exec.h include/g6lc_apu_tgsi.h \
		include/g6lc_apu_tgsi_job.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ src/crt0.S src/apu_tgsi_cc.c \
		src/g6lc_apu_tgsi.c src/g6lc_apu_tgsi_job.c

apu_tgsi_cc.bin: apu_tgsi_cc.elf
	$(OBJCOPY) -O binary $< $@

../../verif/tb/apu/apu_tgsi_cc.hex: apu_tgsi_cc.bin bin2hex.py
	python3 bin2hex.py apu_tgsi_cc.bin $@

clean:
	rm -f apu_fw.elf apu_fw.bin apu_tgsi_fw.elf apu_tgsi_fw.bin apu_tgsi.hex \
	      apu_tgsi_cc.elf apu_tgsi_cc.bin \
	      enc_check tgsi_check tgsi_fw_check map_check boot_check load_check \
	      osbi_check
