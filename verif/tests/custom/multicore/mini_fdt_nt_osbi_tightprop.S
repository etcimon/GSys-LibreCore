# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S1 phase-2 probe. Same tight 5 c.sdsp + stock tail (phase 1), then
# software-correct s2/s3 from immediates (not the aliased load) and a
# bounded fdt_next_tag walk like namelen FDT_PROP.
#
# Stock: phase 1 s3 is stale; walk should still complete if phase 2 is
# only an artifact of keep/wrprio/nackinv. Hang or walk-clobber means
# nested next_tag after the 5-save window is itself red.
#
# tohost (odd => TB >>1):
#   1 both ok; 3/5/7 phase1 s3/s2/both, walk ok;
#   9 walk s3; 11 walk s2; 13 FDT; 15 nextoff0; 17 bad tag; 25/27 trap
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
  jal  namelen_tight
  # Phase 1 snapshot (aliased restore), then force-correct.
  li   s10, 1
  li   t0, 0x80046f2c
  beq  s3, t0, 1f
  li   s10, 3
1:
  li   t0, 0x8001e000
  beq  s2, t0, 2f
  li   t1, 3
  beq  s10, t1, 3f
  li   s10, 5
  j    2f
3:
  li   s10, 7
2:
  la   t0, ph1
  sw   s10, 0(t0)
  li   s2, 0x8001e000
  li   s3, 0x80046f2c
  li   s1, 0
  li   s4, 24
walk:
  la   a2, nextoff
  mv   a1, s1
  mv   a0, s2
  jal  osbi_next_tag
  li   t0, 0x8001e000
  bne  s2, t0, fail11
  li   t0, 0x80046f2c
  bne  s3, t0, fail9
  bltz a0, fail17
  li   t0, 9
  beq  a0, t0, walk_done
  la   t0, nextoff
  lw   s1, 0(t0)
  beqz s1, fail15
  addi s4, s4, -1
  bnez s4, walk
walk_done:
  la   t0, ph1
  lw   a0, 0(t0)
  la   t0, tohost
  sw   a0, 0(t0)
4: j    4b

hart1:
  wfi
  j    hart1

warmup:
  li   t0, 800
  li   t1, 0x80045e00
  li   t4, 0x80046e00
5:
  sd   t0, 0(t1)
  sd   t0, 8(t1)
  sd   t0, 0(t4)
  sd   t0, 0x20(t4)
  sd   t0, 0x38(t4)
  ld   t2, 0(t1)
  ld   t3, 0x38(t4)
  addi t0, t0, -1
  bnez t0, 5b
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
  li   s4, 3
  addi a2, s0, -116
  mv   a1, s1
  mv   a0, s2
  jal  osbi_next_tag
  ld   ra, 136(sp)
  ret

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
fail15:
  li   a0, 15
  j    fail_exit
fail17:
  li   a0, 17
  j    fail_exit
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
6: j    6b

trap:
  csrr t0, mepc
  li   t1, 0x80012eb2
  bne  t0, t1, 7f
  li   a0, 27
  j    fail_exit
7:
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
  .align 2
nextoff:
  .word 0
ph1:
  .word 0

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
