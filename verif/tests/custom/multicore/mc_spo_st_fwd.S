# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Speculative store-to-load forward (same-core RAW).
#
# Bare-metal (no CRT): the CRT+syscalls path can hang in init_tls/memset under
# Verilator multi-PHDR preload before main is reached; bare-metal isolates the
# LSU forward check (matches mini_spo_st_fwd). Spike + Variane both accept
# tohost=1 as PASS (exit code 0).

  .section .text.init
  .globl _start
  .globl main
_start:
main:
  # DRAM stack (below typical CRT image, above tohost page)
  li   sp, 0x80008000

  li   t0, 0xCAFEBABEDEADBEEF
  sd   t0, 0(sp)
  # ALU noise between store and load (speculative window)
  li   t1, 1
  add  t1, t1, t1
  add  t1, t1, t1
  ld   t2, 0(sp)
  bne  t0, t2, fail
  li   t3, 4
  bne  t1, t3, fail

  li   t0, 0x0123456789ABCDEF
  sd   t0, 16(sp)
  ld   t2, 16(sp)
  bne  t0, t2, fail

  li   a0, 1
  j    write_tohost

fail:
  li   a0, 3

write_tohost:
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
