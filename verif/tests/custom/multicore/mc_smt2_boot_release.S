# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la t1, trap
  csrw mtvec, t1
  li s0, 0x02000000
  beqz t0, primary
  li t1, 2
  beq t0, t1, secondary
  li t1, 4
  bgeu t0, t1, park
  slli t0, t0, 2
  add t0, s0, t0
  li t1, 1
  sw t1, 0(t0)
  fence rw, rw
  j park
secondary:
  sw zero, 8(s0)
  fence rw, rw
  j park
primary:
  li t1, 1
  sw t1, 8(s0)
  fence rw, rw
  li t2, 100000
wait:
  lw t3, 8(s0)
  bnez t3, retry
  lw t3, 4(s0)
  beqz t3, retry
  lw t3, 12(s0)
  beqz t3, retry
#ifdef ORACLE_NEGATIVE
  li a0, 3
#else
  li a0, 1
#endif
  j done
retry:
  addi t2, t2, -1
  bnez t2, wait
  li a0, 5
done:
  la t0, tohost
  sw a0, 0(t0)
  fence rw, rw
park:
  j park
trap:
  csrr a0, mcause
  slli a0, a0, 1
  ori a0, a0, 1
  addi a0, a0, 32
  j done

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
