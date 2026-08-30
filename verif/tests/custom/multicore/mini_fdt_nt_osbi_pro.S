# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S1 bisect of namelen.bin mid-saves (b1-nt-pro0b FAIL s2).
# far: 5 sd to 0x80048000. one: sd s11,40(sp). five: stock 1306a–13072.
# Check s3 then s2 after 2nd next_tag.
#
# tohost (odd => TB >>1): 1 PASS; far 21/23; one 17/19; five 3/5; 7 check_node; 25/27 trap

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
  jal  namelen_five
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

# Common nest: prologue, check_node. a7 selects mid-saves. Then 2nd next_tag.
# a7=0 far 5 sd; a7=1 one sd 40(sp); a7=2 stock five mid-saves.
namelen_far:
  li   a7, 0
  j    namelen_body
namelen_one:
  li   a7, 1
  j    namelen_body
namelen_five:
  li   a7, 2
  j    namelen_body
namelen_five_fence:
  li   a7, 3
  j    namelen_body

namelen_body:
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
  mv   s10, a7
  mv   s2, a0
  jal  osbi_check_node
  bltz a0, fail7
  mv   s1, a0
  mv   a7, s10
  beqz a7, mid_far
  li   t0, 1
  beq  a7, t0, mid_one
  sd   s4, 96(sp)
  sd   s6, 80(sp)
  sd   s7, 72(sp)
  sd   s8, 64(sp)
  sd   s11, 40(sp)
  li   t0, 3
  beq  a7, t0, mid_fence
  j    mid_done
mid_fence:
  fence rw, rw
  j    mid_done
mid_far:
  li   t1, 0x80048000
  sd   s4, 0(t1)
  sd   s6, 8(t1)
  sd   s7, 16(t1)
  sd   s8, 24(t1)
  sd   s11, 32(t1)
  j    mid_done
mid_one:
  sd   s11, 40(sp)
mid_done:
  li   s4, 3
  addi a2, s0, -116
  mv   a1, s1
  mv   a0, s2
  jal  osbi_next_tag
  mv   a7, s10
  li   t0, 0x80046f2c
  bne  s3, t0, fail_s3
  li   t0, 0x8001e000
  bne  s2, t0, fail_s2
  ld   ra, 136(sp)
  ld   s1, 120(sp)
  ld   s2, 112(sp)
  ld   s3, 104(sp)
  ld   s5, 88(sp)
  ld   s9, 56(sp)
  ld   s10, 48(sp)
  ret

fail_s3:
  beqz a7, fail21
  li   t0, 1
  beq  a7, t0, fail17
  li   t0, 3
  beq  a7, t0, fail9
  j    fail3
fail_s2:
  beqz a7, fail23
  li   t0, 1
  beq  a7, t0, fail19
  li   t0, 3
  beq  a7, t0, fail11
  j    fail5

namelen_p1:
  sd   ra, 136(sp)
  sd   s1, 120(sp)
  sd   s2, 112(sp)
  sd   s3, 104(sp)
  sd   s5, 88(sp)
  sd   s9, 56(sp)
  sd   s10, 48(sp)
  addi s0, sp, 144
  sd   s4, 96(sp)
  sd   s6, 80(sp)
  sd   s7, 72(sp)
  sd   s8, 64(sp)
  sd   s11, 40(sp)
  li   a0, 0x8001e000
  li   a1, 0
  la   a2, propname
  li   a3, 11
  li   a4, 0x80046f2c
  sw   zero, 0(a4)
  mv   s5, a3
  mv   s3, a4
  mv   s10, a5
  mv   s2, a0
  jal  osbi_check_node
  bltz a0, fail13
  mv   s1, a0
  li   s4, 3
  addi a2, s0, -116
  mv   a1, s1
  mv   a0, s2
  jal  osbi_next_tag
  li   t0, 0x8001e000
  bne  s2, t0, fail11
  li   t0, 0x80046f2c
  bne  s3, t0, fail9
  # stock 130b2: by_offset then check_prop then 3rd next_tag
  mv   a2, s3
  mv   a1, s1
  mv   a0, s2
  jal  osbi_by_offset
  mv   a1, s1
  mv   a0, s2
  la   t0, osbi_check_node
  addi t0, t0, 0x36
  jalr t0
  addi a2, s0, -116
  mv   a1, s1
  mv   a0, s2
  jal  osbi_next_tag
  li   t0, 0x8001e000
  bne  s2, t0, fail11
  li   t0, 0x80046f2c
  bne  s3, t0, fail9
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
fail9:
  li   a0, 9
  j    fail_exit
fail11:
  li   a0, 11
  j    fail_exit
fail13:
  li   a0, 13
  j    fail_exit
fail17:
  li   a0, 17
  j    fail_exit
fail19:
  li   a0, 19
  j    fail_exit
fail21:
  li   a0, 21
  j    fail_exit
fail23:
  li   a0, 23
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
