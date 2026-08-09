# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Xg6lcai T0 queue path (pre-P3 stub):
#   - aiqctl[0]=0 → ai.enq returns all-ones
#   - aiqctl[0]=1 → enq returns tickets 0,1; poll(0)/poll(1) complete; poll(99) pending
#   - ai.qfence is a no-op success
# Soft-pass if AI / Queues CSRs illegal.

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  # ais = Initial
  csrr t0, 0x802
  li   t1, ~(0x3 << 6)
  and  t0, t0, t1
  li   t1, (0x1 << 6)
  or   t0, t0, t1
  csrw 0x802, t0

  # Program ring base (S-mode CSR; we are in M so allowed)
  li   t0, 0x80010000
  csrw 0x5C0, t0               # aiqbase
  csrw 0x5C2, zero             # aiqhead

  # Queue disabled: enq → -1
  # enq a0,a1: f7=0 rs2=0 rs1=11 f3=101 rd=10 op=0x5B → 0x0005D55B
  csrw 0x5C1, zero             # aiqctl
  li   a1, 0x80010000          # desc ptr (ignored by stub)
  .word 0x0005D55B             # ai.enq a0, a1
  li   t0, -1
  bne  a0, t0, fail

  # Enable queue: aiqctl[0]=1, log2 depth = 6 (64), qid=0
  li   t0, 0x61
  csrw 0x5C1, t0

  .word 0x0005D55B             # enq → ticket 0
  bnez a0, fail
  mv   s1, a0

  .word 0x0005D55B             # enq → ticket 1
  li   t0, 1
  bne  a0, t0, fail
  mv   s2, a0

  # poll a0,a1: f7=1 → 0x0205D55B
  # Retired tickets must not stay pending. Status may be 1 (T0 stub OK) or
  # 2 (island completed empty/latched desc with AI-3/version error) — both
  # mean the ticket left the queue. Future ticket 99 stays pending (0).
  mv   a1, s1
  .word 0x0205D55B             # ai.poll a0, a1
  beqz a0, fail
  li   t0, 2
  bgtu a0, t0, fail

  mv   a1, s2
  .word 0x0205D55B
  beqz a0, fail
  li   t0, 2
  bgtu a0, t0, fail

  li   a1, 99
  .word 0x0205D55B
  bnez a0, fail

  # qfence: f7=2 f3=101 rd=0 → 0x0400505B
  .word 0x0400505B

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j 1b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
2: j 2b

trap_vec:
  csrr t0, mcause
  li   t1, 2
  bne  t0, t1, fail
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
3: j 3b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
