# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S1/B1 reproducer: load rd == rs1 on FDT header (fdt_ro_probe_ pattern).
# libfdt's fdt_ro_probe_ does `lbu a5, 38(a5)` / `lbu a5, 26(a5)` while
# walking the FDT header. If the core fails to update a5, the probe returns
# FDT_ERR_BADVERSION and OpenSBI hangs at coldboot. This mini checks the
# exact byte sequence and the assembled 32-bit header words.

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80046ef0
  la   t0, trap
  csrw mtvec, t0

  li   a5, 0x8001e000          # FDT base

  # Test 1: rd==rs1 byte loads on offsets 36-39 (size_dt_struct = 0x8fc)
  lbu  a4, 36(a5)              # 0x00
  lbu  a3, 37(a5)              # 0x00
  lbu  a2, 39(a5)              # 0xfc
  lbu  a5, 38(a5)              # 0x08  <-- rd == rs1
  slliw a4, a4, 0x18
  slliw a3, a3, 0x10
  or   a4, a4, a3
  or   a4, a4, a2
  slliw a5, a5, 0x8
  or   a5, a5, a4
  sext.w a5, a5
  li   t0, 0x8fc
  bne  a5, t0, fail5

  # Test 2: rd==rs1 byte load on offset 0 (magic first byte = 0xd0)
  li   a5, 0x8001e000
  lbu  a5, 0(a5)               # rd == rs1
  li   t0, 0xd0
  bne  a5, t0, fail13

  # PASS
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

hart1:
  wfi
  j    hart1

trap:
  li   a0, 25
  j    fail_exit

fail5:
  li   a0, 5
  j    fail_exit
fail13:
  li   a0, 13
  j    fail_exit

fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

  .section .dtb, "a"
  .incbin "verif/tests/custom/multicore/osbi_nt/dtb.bin"

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
