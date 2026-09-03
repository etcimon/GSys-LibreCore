# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Capability window must advertise I1 live geometry:
#   clusters=1, macs/cycle=256 (PeLanes), AccTile M/N/K log2 = 8 (tile=256).
# Dual-mode I3: default Cas=0 / MaxAROut=2, or +define+G6LC_AI_DRAM_TIMING
# (class-0 SRAM + Cas=14 / MaxAROut=8). Soft-pass if island is an error slave.

  .equ AI_BASE,        0x40000000
  .equ CAP_VER,        0x00
  .equ CAP_CLUSTERS,   0x04
  .equ CAP_MACS,       0x08
  .equ CAP_BLOCK_MNK,  0x14
  .equ CAP_DRAM,       0x18
  .equ CAP_DRAM_CLASS, 0x34
  .equ CAP_DRAM_CHANS, 0x38
  .equ CAP_NOC_WIDTH,  0x3C
  .equ CAP_MAX_AR_OUT, 0x40
  .equ CAP_DRAM_TIMING,0x44
  .equ CAP_DRAM_STATUS,0x48
  .equ CAP_CH_R0,      0x50
  .equ CAP_CH_R1,      0x54
  .equ CAP_CH_W0,      0x70
  .equ CAP_CH_W1,      0x74

  .section .text.init
  .globl _start
_start:
  li   sp, 0x80008000
  la   t0, trap_vec
  csrw mtvec, t0
  andi sp, sp, -16

  li   s0, AI_BASE

  lw   t0, CAP_VER(s0)
  slli t0, t0, 48
  srli t0, t0, 48
  li   t1, 1
  bne  t0, t1, fail

  # F8: [15:0] present, [31:16] enabled — live SKU is 1/1
  lw   t0, CAP_CLUSTERS(s0)
  li   t1, 0x00010001
  bne  t0, t1, fail

  lw   t0, CAP_MACS(s0)
  li   t1, 256
  bne  t0, t1, fail

  # packed log2(K)|log2(N)|log2(M) in low 12 bits — expect 8,8,8
  lw   t0, CAP_BLOCK_MNK(s0)
  andi t1, t0, 0xF
  li   t2, 8
  bne  t1, t2, fail
  srli t1, t0, 4
  andi t1, t1, 0xF
  bne  t1, t2, fail
  srli t1, t0, 8
  andi t1, t1, 0xF
  bne  t1, t2, fail

  # I3: class 0 nameplate 8; class 1 nameplate N×19. Shift always 6.
  lw   t0, CAP_NOC_WIDTH(s0)
  li   t1, 64
  bne  t0, t1, fail
  lw   s1, CAP_DRAM_CLASS(s0)
  lw   t0, CAP_DRAM(s0)
  li   t1, 0xFFFF
  and  s2, t0, t1
  lw   t0, CAP_DRAM_CHANS(s0)
  li   t1, 0xFFFF
  and  s3, t0, t1
  srli t2, t0, 16
  andi t2, t2, 0xFF
  li   t1, 6
  bne  t2, t1, fail
  lw   s4, CAP_DRAM_TIMING(s0)
  lw   s5, CAP_MAX_AR_OUT(s0)
  beqz s1, cap_c0
  li   t1, 1
  bne  s1, t1, fail
  # class 1: gbps = 19 * nch; Cas=14; MaxAROut=8
  li   t1, 19
  mul  t1, t1, s3
  bne  s2, t1, fail
  li   t1, 0x000E0E0E
  bne  s4, t1, fail
  li   t1, 8
  bne  s5, t1, fail
  j    status
cap_c0:
  li   t1, 8
  bne  s2, t1, fail
  beqz s4, cap_c0_live
  li   t1, 0x000E0E0E
  bne  s4, t1, fail
  li   t1, 8
  bne  s5, t1, fail
  j    status
cap_c0_live:
  li   t1, 2
  bne  s5, t1, fail

status:
  # I3: class-0 SRAM init_done=1; timing_en iff Cas!=0
  lw   t0, CAP_DRAM_STATUS(s0)
  andi t1, t0, 1
  beqz t1, fail
  lw   t2, CAP_DRAM_TIMING(s0)
  snez t2, t2
  srli t0, t0, 1
  andi t0, t0, 1
  xor  t0, t0, t2
  bnez t0, fail

  # S5: occupancy words are readable. N=1 maps every stripe to ch0, so ch1
  # stays 0. Do not require ch0 != 0 (no DRAM traffic in this ELF).
  lw   t0, CAP_CH_R0(s0)
  lw   t0, CAP_CH_W0(s0)
  li   t1, 1
  bne  s3, t1, pass
  lw   t0, CAP_CH_R1(s0)
  bnez t0, fail
  lw   t0, CAP_CH_W1(s0)
  bnez t0, fail

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
  # Bus error → soft-pass (island absent)
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
