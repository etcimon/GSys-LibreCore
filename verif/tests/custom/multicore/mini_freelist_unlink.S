# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Soft-ladder iter-010: OpenSBI sbi_malloc freelist unlink shape
#   ld a1,0(a4); ld a0,8(a4); sd a1,0(a0); sd a0,8(a1)
# Historic PEEL_MALLOC pin: sd @f0ba mcause=6 (misaligned / poison ptr).
#
# Gate: g6lc64_smt2 DI; tohost=1 pass, 3 fail.

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  # Three nodes in a doubly-linked free list (OpenSBI heap node-ish):
  #   node: +0 next, +8 prev  (simplified)
  la   s0, node0
  la   s1, node1
  la   s2, node2

  # Circular-ish free list: head sentinel at node0; free block node1
  # node0.next = node1, node0.prev = node2
  # node1.next = node2, node1.prev = node0
  # node2.next = node0, node2.prev = node1
  sd   s1, 0(s0)
  sd   s2, 8(s0)
  sd   s2, 0(s1)
  sd   s0, 8(s1)
  sd   s0, 0(s2)
  sd   s1, 8(s2)

  # Unlink node1 (a4 = node1) — stock malloc shape
  mv   a4, s1
  ld   a1, 0(a4)          # next
  ld   a0, 8(a4)          # prev
  # poison markers like OpenSBI (optional dual-issue neighbors)
  li   a2, 0x3eb7aabe
  li   a3, 0x37ab6eef
  sd   a1, 0(a0)          # prev->next = next
  sd   a0, 8(a1)          # next->prev = prev
  sd   a2, 0(a4)          # poison node
  sd   a3, 8(a4)

  # Check: node0.next == node2, node2.prev == node0
  ld   t1, 0(s0)
  bne  t1, s2, fail
  ld   t1, 8(s2)
  bne  t1, s0, fail

  # Repeat unlink thrashing with dual-issue ALU between loads
  # Rebuild list and unlink 32 times
  li   s3, 32
1:
  sd   s1, 0(s0)
  sd   s2, 8(s0)
  sd   s2, 0(s1)
  sd   s0, 8(s1)
  sd   s0, 0(s2)
  sd   s1, 8(s2)
  mv   a4, s1
  ld   a1, 0(a4)
  li   t2, 1
  add  t2, t2, t2         # dual-issue neighbor
  ld   a0, 8(a4)
  sd   a1, 0(a0)
  sd   a0, 8(a1)
  ld   t1, 0(s0)
  bne  t1, s2, fail
  addi s3, s3, -1
  bnez s3, 1b

  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

trap:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
3: j    3b

fail:
  li   a0, 3
  la   t0, tohost
  sw   a0, 0(t0)
4: j    4b

  .section .data
  .align 6
node0: .dword 0, 0, 0, 0
node1: .dword 0, 0, 0, 0
node2: .dword 0, 0, 0, 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
