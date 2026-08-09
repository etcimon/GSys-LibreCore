# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder B1 (cont.19): dual c.mv after ld s3 — s3 must stay the loaded
# pointer (not AXI poison ca11ab1e). Soft ladder nops both c.mvs; this test
# keeps natural c.mv pair + consumer ld.
#
# Gate: g6lc64_smt2 DI; tohost=1 pass, 3 fail.

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # Fake "module table": s4 → entry; entry → payload word
  li   s4, 0x80007000
  li   t0, 0x80007080
  sd   t0, 0(s4)               # *s4 = module ptr
  li   t1, 0x1234567890abcdef
  sd   t1, 0(t0)               # *module = payload

  li   s1, 0x1111              # c.mv sources (args)
  li   s2, 0x2222

  # Cont.19 sequence shape
  ld   s3, 0(s4)               # module ptr
  c.mv a1, s1
  c.mv a0, s2
  ld   a2, 0(s3)               # must use good s3

  li   t3, 0x1234567890abcdef
  bne  a2, t3, fail
  # s3 still the module pointer
  li   t4, 0x80007080
  bne  s3, t4, fail
  # a0/a1 received moves
  li   t5, 0x2222
  bne  a0, t5, fail
  li   t5, 0x1111
  bne  a1, t5, fail

  # PASS
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

trap:
  # If s3 was poison, load faults or we land here
  li   a0, 3
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
