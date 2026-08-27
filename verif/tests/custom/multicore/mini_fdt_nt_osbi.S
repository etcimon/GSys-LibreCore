# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S1 trampoline: stock namelen_@13040 (cave nop'd) + by_offset_@12e26
# (cave nop'd) + check_node/prop + next_tag at pin VAs. 2nd next_tag is
# the TRACE jal @1307e. get_string stubbed (li a0,0; ret). Hart1 spin +
# alias-line warmup kept. Pin = trap mepc=0x80012eb2 (tohost 27).
#
# tohost (odd => TB >>1):
#   1 SUCCESS
#   3 s3 clobber after 2nd next_tag
#   5 s2 clobber
#   7 s2/s3 lost across check_node
#   9 check_node fail
#   25 trap
#

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
  mv   a0, t0
  li   a1, 0
  la   a2, propname
  li   a3, 11
  li   a4, 0x80046f2c
  sw   zero, 0(a4)
  jal  osbi_namelen
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

# Hart1: store-spin on set-conflict line so SMT switch-on-miss lands in the walk.
hart1:
  li   sp, 0x80048000
  li   t1, 0x80047e00
2:
  sd   t1, 0(t1)
  sd   t1, 64(t1)
  ld   t2, 0(t1)
  j    2b

# STQ/D$ occupancy on the TRACE alias line (0x80046e38) and a same-set neighbour.
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

# 32B like stock check_node; jal stock next_tag so we keep the tag in a0.
check_node:
  addi sp, sp, -32
  sd   s0, 16(sp)
  sd   ra, 24(sp)
  addi s0, sp, 32
  sw   a1, -20(s0)
  addi a2, s0, -20
  jal  osbi_next_tag
  lw   t0, -20(s0)
  la   t1, nextoff
  sw   t0, 0(t1)
  ld   ra, 24(sp)
  ld   s0, 16(sp)
  addi sp, sp, 32
  ret

namelen:
  # Stock namelen_ is 144B; TRACE SP=0x80046e60, lenp=0x80046f2c, 2nd a2=0x80046e7c.
  addi sp, sp, -144
  sd   ra, 136(sp)
  sd   s0, 128(sp)
  sd   s1, 120(sp)
  sd   s2, 112(sp)
  sd   s3, 104(sp)
  addi s0, sp, 144
  li   t0, 0x8001e000
  lbu  t1, 0(t0)
  li   t2, 0xd0
  bne  t1, t2, fail13
  lbu  t1, 56(t0)
  bnez t1, fail15
  lbu  t1, 59(t0)
  li   t2, 1
  bne  t1, t2, fail15
  mv   a0, t0
  li   a1, 0
  li   a2, 4
  jal  osbi_offset_ptr
  beqz a0, fail17
  li   t0, 0x8001e038
  bne  a0, t0, fail19
  li   s2, 0x8001e000
  li   s3, 0x80046f2c
  sw   zero, 0(s3)
  mv   a0, s2
  li   a1, 0
  jal  osbi_check_node
  bltz a0, fail9
  mv   a1, a0
  la   t1, nextoff
  sw   a1, 0(t1)
  li   t0, 0x8001e000
  bne  s2, t0, fail7
  li   t0, 0x80046f2c
  bne  s3, t0, fail7
  la   t1, nextoff
  lw   a1, 0(t1)
  addi a2, s0, -116
  sw   a1, 0(a2)
  mv   a0, s2
  jal  osbi_next_tag
  li   t0, 0x8001e000
  bne  s2, t0, fail5
  li   t0, 0x80046f2c
  bne  s3, t0, fail3
  ld   ra, 136(sp)
  ld   s0, 128(sp)
  ld   s1, 120(sp)
  ld   s2, 112(sp)
  ld   s3, 104(sp)
  addi sp, sp, 144
  ret

# 1st next_tag returned a0 != 1; report 65+2*tag (TB >>1 = 32+tag) if tag<32.
fail_tag:
  li   t0, 32
  bgeu a0, t0, fail9
  slli a0, a0, 1
  addi a0, a0, 65
  j    fail_exit

fail3:
  li   a0, 3
  j    fail_exit
fail5:
  li   a0, 5
  j    fail_exit
fail7:
  li   a0, 7
  j    fail_exit
fail9:
  li   a0, 9
  j    fail_exit
fail13:
  li   a0, 13
  j    fail_exit
fail15:
  li   a0, 15
  j    fail_exit
fail17:
  li   a0, 17
  j    fail_exit
fail19:
  li   a0, 19
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

  .section .text.namelen, "ax"
  .globl osbi_namelen
osbi_namelen:
  .incbin "verif/tests/custom/multicore/osbi_nt/namelen.bin"

  .section .dtb, "a"
  .incbin "verif/tests/custom/multicore/osbi_nt/dtb.bin"

  .section .jtab, "a"
  .incbin "verif/tests/custom/multicore/osbi_nt/jtab.bin"

  .section .data
  .align 3
lenp:
  .word 0
nextoff:
  .word 0
propname:
  .asciz "compatible"

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
