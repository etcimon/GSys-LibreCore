# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# G1dm: leftover `jal` to a far target (`+0x3100`, OpenSBI
# scratch_init distance). Near leftover jal PASS. Isolated
# jalr+bnez PASS. OpenSBI `jal@7c6` still does not retire.
#
# tohost=1 pass. Fail N is ((N<<1)|1) → printed N.
#   1  helper did not return 1
#   2  second-pass bnez fall-through
#   4  first pass took bnez (ret0)
#   6  ops[1] jalr returned nonzero
#   8  leftover jal skipped (a0 still s2)
#  10  after a0=1 then csrr mhartid, a0 != 0 (not hart0)
#  12  c.mv s1,a0 kept stale 1 (7be would skip scratch_init)
#  14  750-shape jalr returned 0 (bnez@752 did not take)
#  16  7bc-shape c.bnez a0 took (stale a0=1 / csrr late)
# Hart1 parks on mhartid.

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, park
  li   sp, 0x80008000
  la   t0, trap
  csrw mtvec, t0

  la   s4, ops
  li   s11, 0
  la   a5, ret0
  j    jalr_site
taken:
  bnez s11, taken_ok
  li   a0, 9
  j    fail
taken_ok:
  li   t0, 1
  bne  a0, t0, fail1
  la   s4, plat
  la   a5, ret1
  li   a0, 0
  ld   a5, 96(s4)
  c.mv s1, a0
  c.ld a5, 8(a5)
  c.beqz a5, p2_ok
  c.jalr a5
  .option norvc
  bnez a0, fail3
  .option rvc
p2_ok:
  la   s2, scratch
  li   s1, 0
  .align 4
p3_pred:
  c.bnez s1, fail4
p3_site:
  c.mv a0, s2
  .option norvc
  ld   s1, 72(s2)
  jal  far_ret0
  bnez a0, fail4
  .option rvc
  # G1ed: OpenSBI 750 leftover-pending then 7a2–7be.
  # Aligned c.jalr + RVI bnez + leftover ld; helper
  # returns 1; 7a8 I|I addi+csrr while leftover is
  # still pending (next line of 750 is not fetched).
  # Isolated P4 / leftover jal stay.
  la   s4, plat
  la   a5, ret1
  li   a0, 0
  .align 3
p4_jalr:
  c.jalr a5
  .option norvc
  bnez a0, p4_win
  ld   a5, 96(s4)
  .option rvc
  j    fail7
  .skip 24
  .align 3
p4_win:
  c.nop
  c.li a1, 1
  .option norvc
  auipc a0, 0
  addi  a0, a0, 0
  csrr  a0, mhartid
  .option rvc
  la    s4, plat
  .align 3
p5_b0:
  ld    a5, 96(s4)
  c.mv  s1, a0
  c.ld  a5, 8(a5)
  .align 3
p5_b8:
  c.beqz a5, p5_ok
  c.jalr a5
  c.bnez a0, fail8
  c.nop
p5_ok:
  bnez  a0, fail5
  c.bnez s1, fail6
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

  .align 3
jalr_site:
  c.jalr a5
  .option norvc
  bnez a0, taken
  ld   a5, 0(s4)
  .option rvc
  bnez s11, fail2
  li   s11, 1
  la   a5, ret1
  j    jalr_site

fail1:
  li   a0, 3
  j    fail
fail2:
  li   a0, 5
  j    fail
fail3:
  li   a0, 13
  j    fail
fail4:
  li   a0, 17
  j    fail
fail5:
  li   a0, 21
  j    fail
fail6:
  li   a0, 25
  j    fail
fail7:
  li   a0, 29
  j    fail
fail8:
  li   a0, 33
  j    fail
fail:
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

ret0:
  li   a0, 0
  ret
ret1:
  li   a0, 1
  ret
  .skip 0x3100
  .align 2
far_ret0:
  li   a0, 0
  ret

park:
  wfi
  j    park

trap:
  li   a0, 7
  j    fail

  .section .data
  .align 3
ops:
  .dword 0
  .align 3
plat:
  .zero 96
  .dword ops2
ops2:
  .dword ret1
  .dword ret0
  .align 3
scratch:
  .zero 128

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
