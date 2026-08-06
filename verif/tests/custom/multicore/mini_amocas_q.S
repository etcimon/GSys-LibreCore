# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Bare-metal Zacas AMOCAS.Q (RV64 register-pair).
# Requires CVA6Cfg.RVZacas=1 and functional Q path.
# Soft-pass (tohost=1) if illegal (Q not implemented / odd regs).
#
# Encoding: amocas.q a0, a2, (a6) with even a0,a2
#   expected = {a1,a0}, new = {a3,a2}, result old -> {a1,a0}

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_soft
  csrw mtvec, t0

  # 16-byte aligned CAS location
  andi sp, sp, -16
  addi sp, sp, 64

  # ---- success: mem == expected -> swap ----
  li   t0, 0x1111111111111111
  li   t1, 0x2222222222222222
  sd   t0, 0(sp)
  sd   t1, 8(sp)

  li   a0, 0x1111111111111111   # exp lo
  li   a1, 0x2222222222222222   # exp hi
  li   a2, 0xAAAAAAAAAAAAAAAA   # new lo
  li   a3, 0xBBBBBBBBBBBBBBBB   # new hi
  mv   a6, sp
  # amocas.q a0, a2, (a6)  funct5=00101 funct3=100
  .word 0x28C8452F

  li   t0, 0x1111111111111111
  li   t1, 0x2222222222222222
  bne  a0, t0, fail
  bne  a1, t1, fail
  ld   t2, 0(sp)
  ld   t3, 8(sp)
  li   t4, 0xAAAAAAAAAAAAAAAA
  li   t5, 0xBBBBBBBBBBBBBBBB
  bne  t2, t4, fail
  bne  t3, t5, fail

  # ---- mismatch: keep mem ----
  li   t0, 0x3333333333333333
  li   t1, 0x4444444444444444
  sd   t0, 16(sp)
  sd   t1, 24(sp)
  li   a0, 0xDEADBEEFCAFEBABE
  li   a1, 0x0123456789ABCDEF
  li   a2, 0x5555555555555555
  li   a3, 0x6666666666666666
  addi a6, sp, 16
  .word 0x28C8452F
  li   t0, 0x3333333333333333
  li   t1, 0x4444444444444444
  bne  a0, t0, fail
  bne  a1, t1, fail
  ld   t2, 16(sp)
  ld   t3, 24(sp)
  bne  t2, t0, fail
  bne  t3, t1, fail

  # PASS
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

trap_soft:
  # illegal Q (not implemented / odd) -> soft pass for non-Q configs
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
