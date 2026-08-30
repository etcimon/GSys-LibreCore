# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S1: tight + 1 c.nop after the five c.sdsp. Still s3 clobber
# (b1-nt-nl-tightnop1 FAIL tohost=1 @10632).
#
# tohost (odd => TB >>1): 1 PASS; 3 s3; 5 s2; 13 magic; 25/27 trap

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80046ef0
  la   t0, trap
  csrw mtvec, t0
  jal  warmup
  li   t0, 0x8001e000
  lbu  t1, 0(t0)
  li   t2, 0xd0
  bne  t1, t2, fail13
  jal  namelen_tight
  li   t0, 0x80046f2c
  bne  s3, t0, fail3
  li   t0, 0x8001e000
  bne  s2, t0, fail5
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

hart1:
  wfi
  j    hart1

warmup:
  li   t0, 800
  li   t1, 0x80045e00
  li   t4, 0x80046e00
3:
  sd   t0, 0(t1)
  sd   t0, 8(t1)
  sd   t0, 0(t4)
  sd   t0, 0x20(t4)
  sd   t0, 0x38(t4)
  ld   t2, 0(t1)
  ld   t3, 0x38(t4)
  addi t0, t0, -1
  bnez t0, 3b
  ret

namelen_tight:
  sd   ra, 136(sp)
  sd   s1, 120(sp)
  sd   s2, 112(sp)
  sd   s3, 104(sp)
  sd   s5, 88(sp)
  sd   s9, 56(sp)
  sd   s10, 48(sp)
  addi s0, sp, 144
  li   a0, 0x8001e000
  li   a1, 0
  la   a2, propname
  li   a3, 11
  li   a4, 0x80046f2c
  sw   zero, 0(a4)
  mv   s5, a3
  mv   s3, a4
  mv   s2, a0
  jal  osbi_check_node
  bltz a0, fail7
  mv   s1, a0
  sd   s4, 96(sp)
  sd   s6, 80(sp)
  sd   s7, 72(sp)
  sd   s8, 64(sp)
  sd   s11, 40(sp)
  c.nop
  li   s4, 3
  addi a2, s0, -116
  mv   a1, s1
  mv   a0, s2
  jal  osbi_next_tag
  ld   ra, 136(sp)
  ret

fail3:
  li   a0, 3
  j    fail_exit
fail5:
  li   a0, 5
  j    fail_exit
fail7:
  li   a0, 7
  j    fail_exit
fail13:
  li   a0, 13
  j    fail_exit
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

trap:
  csrr t0, mepc
  li   t1, 0x80012eb2
  bne  t0, t1, 4f
  li   a0, 27
  j    fail_exit
4:
  li   a0, 25
  j    fail_exit

  .section .text.osbi, "ax"
  .align 1
  .globl osbi_offset_ptr
osbi_offset_ptr:
  .incbin "verif/tests/custom/multicore/osbi_nt/offset_ptr.bin"
  .globl osbi_next_tag
osbi_next_tag:
  .incbin "verif/tests/custom/multicore/osbi_nt/next_tag.bin"
  .globl osbi_check_node
osbi_check_node:
  .incbin "verif/tests/custom/multicore/osbi_nt/check_np.bin"

  .section .text.byoff, "ax"
  .globl osbi_by_offset
osbi_by_offset:
  .incbin "verif/tests/custom/multicore/osbi_nt/by_offset.bin"

  .section .text.gstr, "ax"
  .globl osbi_get_string
osbi_get_string:
  li   a0, 0
  ret

  .section .dtb, "a"
  .incbin "verif/tests/custom/multicore/osbi_nt/dtb.bin"

  .section .jtab, "a"
  .incbin "verif/tests/custom/multicore/osbi_nt/jtab.bin"

  .section .data
  .align 3
propname:
  .asciz "compatible"

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
