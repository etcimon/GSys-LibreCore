# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# E1 Verilator witness of the EDK2 SEC ABI.
#
# OvmfPkg/RiscVVirt is a PEI-less S-mode payload for OpenSBI fw_dynamic:
#   a0 = hartid, a1 = FDT (RISC-V boot ABI, same as Linux).
# PlatformSecLib's first act is to consume that FDT. This mini plants a
# stub FDT, presents the ABI, and checks the big-endian FDT magic
# (0xd00dfeed) byte by byte — the same load shape EDK2 SEC uses, not a
# full UEFI FD (Variane cannot boot 32 MiB pflash).
#
# Secondary harts park (EDK2 waits for HSM). tohost=1 pass, 3 fail.
#

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, .Lpark

  # Present the EDK2 SEC ABI to ourselves (OpenSBI would do this).
  mv   a0, t0
  la   a1, fdt_blob

  # a0 must be hart 0.
  bnez a0, fail

  # FDT magic 0xd00dfeed, big-endian, first four bytes.
  lbu  t1, 0(a1)
  li   t2, 0xd0
  bne  t1, t2, fail
  lbu  t1, 1(a1)
  li   t2, 0x0d
  bne  t1, t2, fail
  lbu  t1, 2(a1)
  li   t2, 0xfe
  bne  t1, t2, fail
  lbu  t1, 3(a1)
  li   t2, 0xed
  bne  t1, t2, fail

  # totalsize at offset 4, big-endian, must be >= 32.
  lbu  t1, 4(a1)
  lbu  t2, 5(a1)
  lbu  t3, 6(a1)
  lbu  t4, 7(a1)
  slli t1, t1, 24
  slli t2, t2, 16
  slli t3, t3, 8
  or   t1, t1, t2
  or   t1, t1, t3
  or   t1, t1, t4
  li   t2, 32
  bltu t1, t2, fail

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

.Lpark:
  wfi
  j    .Lpark

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

  .section .rodata
  .align 3
  .globl fdt_blob
fdt_blob:
  .byte 0xd0, 0x0d, 0xfe, 0xed
  .byte 0x00, 0x00, 0x00, 0x20
  .byte 0x00, 0x00, 0x00, 0x10
  .byte 0x00, 0x00, 0x00, 0x10
  .byte 0x00, 0x00, 0x00, 0x11
  .byte 0x00, 0x00, 0x00, 0x10
  .byte 0x00, 0x00, 0x00, 0x00
  .byte 0x00, 0x00, 0x00, 0x10

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
