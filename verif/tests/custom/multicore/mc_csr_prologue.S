# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# OpenSBI `_trap_handler` prologue, replayed in M-mode on hart 0. The
# instruction bytes (including the compressed stack stores that put the
# 32-bit CSR reads on 2-byte alignment) follow fw_payload.elf v1.5:
#   ld t0, 0x60(tp); c.sdsp; csrrw tp,mscratch,tp; csrr t0,mepc; c.sdsp;
#   csrr t0,mstatus
# On g6lc64_ooo_int2 the third CSR access of that run raised ILLEGAL_INSTR
# (plan T7m). Any trap here reports 32 + 2*mcause + 1 through tohost; the
# oracle-negative build reports a distinct failing code on success so the
# classifier is exercised.

  .section .text.init
  .globl _start
_start:
  .option norvc
  csrr t0, mhartid
  la t1, trap
  csrw mtvec, t1
  bnez t0, park
  la tp, scratch
  csrw mscratch, tp
  la sp, stack_top
  li s1, 4000
loop:
  .option rvc
  ld t0, 0x60(tp)
  c.sdsp t0, 0x28(sp)
  csrrw tp, mscratch, tp
  csrr t0, mepc
  c.sdsp t0, 0x100(sp)
  csrr t0, mstatus
  .option norvc
  csrrw tp, mscratch, tp
  addi s1, s1, -1
  bnez s1, loop
#ifdef ORACLE_NEGATIVE
  li a0, 3
#else
  li a0, 1
#endif
  j done
trap:
  csrr a0, mcause
  slli a0, a0, 1
  ori a0, a0, 1
  addi a0, a0, 32
done:
  la t0, tohost
  sw a0, 0(t0)
  fence rw, rw
park:
  j park

  .section .data
  .align 4
scratch: .fill 0x200, 1, 0
  .align 4
stack_bot: .fill 0x400, 1, 0
stack_top:

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
