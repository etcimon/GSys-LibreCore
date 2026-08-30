# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S1 hold class: sbi_ecall_register_extension list walk.
# Insert N nodes (next/prev like list_head), then walk
#   ld a5,0(sentinel); bne a5,sentinel; ld a5,0(a5)
# Fail if a5==0 (NULL walk / stale L1). No same-bank dummy loads
# (see mini_ecall_list_void.S). Unrolled inserts; no jal/fence.
# Cap hang vs mini_freelist_unlink is occupancy/tohost, not fail5.
#
# tohost (odd => TB >>1): 1 PASS; 5 NULL walk; 7 bad count; 25 trap

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  la   s0, sentinel
  la   s1, node0
  la   s2, node1
  la   s3, node2
  la   s4, node3
  # Addresses retired before any sd (freelist shape). Immediate
  # la+c.sd was cap-hang mcause=6 mtval=text.
  mv   t6, s0
  sd   t6, 0(s0)
  sd   t6, 8(s0)

  # Insert 4 nodes fully unrolled (no jal/ret/fence). s1..s4 already set.
  sd   s1, 0(s1)
  sd   s1, 8(s1)
  ld   a5, 8(s0)
  sd   s0, 0(s1)
  sd   a5, 8(s1)
  sd   s1, 0(a5)
  sd   s1, 8(s0)
  sd   s2, 0(s2)
  sd   s2, 8(s2)
  ld   a5, 8(s0)
  sd   s0, 0(s2)
  sd   a5, 8(s2)
  sd   s2, 0(a5)
  sd   s2, 8(s0)
  sd   s3, 0(s3)
  sd   s3, 8(s3)
  ld   a5, 8(s0)
  sd   s0, 0(s3)
  sd   a5, 8(s3)
  sd   s3, 0(a5)
  sd   s3, 8(s0)
  sd   s4, 0(s4)
  sd   s4, 8(s4)
  ld   a5, 8(s0)
  sd   s0, 0(s4)
  sd   a5, 8(s4)
  sd   s4, 0(a5)
  sd   s4, 8(s0)

  # Walk: a3=sentinel, a5=head.next; fail on NULL
  mv   a3, s0
  ld   a5, 0(a3)
  beqz a5, fail5
  beq  a5, a3, fail7
  li   s2, 0
walk:
  addi s2, s2, 1
  li   t0, 8
  bgt  s2, t0, fail7
  ld   a5, 0(a5)
  beqz a5, fail5
  bne  a5, a3, walk
  li   t0, 4
  bne  s2, t0, fail7

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

  .section .data
  .align 6
sentinel: .dword 0, 0
  .align 4
node0:    .dword 0, 0, 0, 0
node1:    .dword 0, 0, 0, 0
node2:    .dword 0, 0, 0, 0
node3:    .dword 0, 0, 0, 0
  .align 4
dummy:    .dword 0
