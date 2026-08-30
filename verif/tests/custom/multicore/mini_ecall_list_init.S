# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S1 hold bisect: INIT_LIST_HEAD at ecall_exts_list PA 0x80040518.
# Address materialised fully (lui/addiw/slli/addi + mv) before any sd —
# back-to-back addi+c.sd is the walk-mini cap hang (mepc sd, mtval text).
#
# tohost (odd => TB >>1): 1 PASS; 5 next==0; 7 next/prev != self; 25 trap

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  li   s0, 0x80040518
  mv   t6, s0
  sd   t6, 0(s0)
  sd   t6, 8(s0)
  ld   a5, 0(s0)
  beqz a5, fail5
  bne  a5, s0, fail7
  ld   a5, 8(s0)
  beqz a5, fail5
  bne  a5, s0, fail7

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

hart1:
  wfi
  j    hart1

fail5:
  li   a0, 5
  j    fail_exit
fail7:
  li   a0, 7
  j    fail_exit
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

trap:
  li   a0, 25
  j    fail_exit

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
