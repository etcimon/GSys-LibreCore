# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Dual-active prove: dual-ready burn (both ready post-grace), then primary
# WFI-yields so peer can score tohost. Pure no-WFI concurrent remains open.
#
# Modes (selected by the reviewer, one at a time):
#   SMT_BALANCE          fixed-work service measurement; balance_active masks the
#                        workers so a solo arm keeps the shared instruction bytes
#   SMT_LRSC_DEP         LR result -> dependent consumer (rs1/SMT_LRSC_RS2/_ALU)
#   SMT_BOOT_RENDEZVOUS  reset-time election and release rendezvous
#   SMT_BOOT_FAULT       oracle negative: corrupts the checked value only

  .section .text.init
  .globl _start
_start:
#ifdef SMT_BALANCE
  la   t0, balance_fail
  csrw mtvec, t0
  csrr s2, mhartid
  li   t0, 2
  bgeu s2, t0, balance_fail
  la   t0, balance_active
  ld   s6, 0(t0)
  li   t0, 1
  sll  t0, t0, s2
  and  t0, t0, s6
  beqz t0, balance_park
  la   s0, balance_state
  slli t0, s2, 6
  add  s0, s0, t0
  li   t0, 1
  sd   t0, 0(s0)
  fence rw, rw
  la   t0, balance_state
balance_barrier:
  ld   t1, 0(t0)
  ld   t2, 64(t0)
  slli t2, t2, 1
  or   t1, t1, t2
  and  t1, t1, s6
  bne  t1, s6, balance_barrier
  li   s1, 512
  li   s3, 0
  addi s4, s2, 1
  bnez s2, balance_begin1
balance_begin0:
  nop
  j    balance_loop
balance_begin1:
  nop
balance_loop:
  add  s3, s3, s4
balance_xor:
  xori s5, s3, 0x55
balance_dec:
  addi s1, s1, -1
balance_branch:
  bnez s1, balance_loop
balance_loop_end:
  bnez s2, balance_end1
balance_end0:
  nop
  j    balance_check
balance_end1:
  nop
balance_check:
  li   t0, 512
  beqz s2, balance_expected
  slli t0, t0, 1
balance_expected:
#ifdef SMT_BOOT_FAULT
  addi t0, t0, 1
#else
  addi t0, t0, 0
#endif
  bne  s3, t0, balance_fail
  xori t1, t0, 0x55
  bne  s5, t1, balance_fail
  sd   s3, 8(s0)
  fence rw, rw
  li   t0, 1
  sd   t0, 16(s0)
  li   t0, 3
  bne  s6, t0, balance_pass
  bnez s2, balance_park
  la   t0, balance_state
balance_wait:
  ld   t1, 80(t0)
  beqz t1, balance_wait
  fence r, rw
  ld   t1, 8(t0)
  li   t2, 512
  bne  t1, t2, balance_fail
  ld   t1, 72(t0)
  li   t2, 1024
  bne  t1, t2, balance_fail
balance_pass:
  li   a0, 1
  j    balance_exit
  .balign 4
balance_fail:
  li   a0, 3
balance_exit:
  la   t0, tohost
  sw   a0, 0(t0)
balance_park:
  wfi
  j    balance_park
#elif defined(SMT_LRSC_DEP)
  la   t0, lr_fail
  csrw mtvec, t0
  csrr s2, mhartid
  la   s0, lr_words
  slli t0, s2, 6
  add  s0, s0, t0
  li   t0, 32
lr_retry:
  mv   a0, s0
  li   a1, 2
  li   a2, 3
  mv   a5, a0
  lr.d.aqrl a0, (a5)
#ifdef SMT_LRSC_RS2
  bne  a1, a0, lr_fail
#elif defined(SMT_LRSC_ALU)
  addi t3, a0, 1
  li   t4, 3
  bne  t3, t4, lr_fail
#else
  bne  a0, a1, lr_fail
#endif
  sc.d.rl a4, a2, (a5)
  beqz a4, lr_done
  addi t0, t0, -1
  bnez t0, lr_retry
  j    lr_fail
lr_done:
  li   t1, 3
  ld   t2, 0(s0)
#ifdef SMT_BOOT_FAULT
  xori t1, t1, 1
#else
  xori t1, t1, 0
#endif
  bne  t2, t1, lr_fail
  la   t0, lr_seen
  li   t1, 1
  sll  t1, t1, s2
  amoor.w.aqrl zero, t1, (t0)
  bnez s2, lr_park
lr_wait:
  lw   t1, 0(t0)
  li   t2, 3
  bne  t1, t2, lr_wait
  li   a0, 1
  j    lr_exit
lr_fail:
  li   a0, 3
lr_exit:
  la   t0, tohost
  sw   a0, 0(t0)
lr_park:
  wfi
  j    lr_park
#elif defined(SMT_BOOT_RENDEZVOUS)
  la   t0, boot_fail
  csrw mtvec, t0
  csrr s2, mhartid
  li   t0, 2
  bgeu s2, t0, boot_fail
  la   s0, rendezvous
  li   t1, 1
  sll  t2, t1, s2
  addi t3, s0, 4
  amoor.w.aqrl zero, t2, (t3)
  amoswap.w.aqrl s1, t1, (s0)
  bnez s1, boot_loser
boot_winner_wait:
  lw   t2, 8(s0)
  beqz t2, boot_winner_wait
  li   t2, 0x13572468
  sw   t2, 16(s0)
  fence rw, rw
  li   t2, 2
  sw   t2, 0(s0)
boot_done_wait:
  lw   t2, 12(s0)
  beqz t2, boot_done_wait
  fence r, rw
  lw   t2, 4(s0)
  li   t3, 3
  bne  t2, t3, boot_fail
  li   a0, 1
  j    boot_exit
boot_loser:
  li   t2, 1
  bne  s1, t2, boot_fail
  sw   t2, 8(s0)
boot_release_wait:
  lw   t2, 0(s0)
  li   t3, 2
  bne  t2, t3, boot_release_wait
  fence r, rw
  lw   t2, 16(s0)
  li   t3, 0x13572468
#ifdef SMT_BOOT_FAULT
  xori t3, t3, 1
#else
  xori t3, t3, 0
#endif
  bne  t2, t3, boot_fail
  li   t2, 1
  sw   t2, 12(s0)
boot_park:
  wfi
  j    boot_park
boot_fail:
  li   a0, 3
boot_exit:
  la   t0, tohost
  sw   a0, 0(t0)
  j    boot_park
#else
  csrr t0, mhartid
  bnez t0, peer_pass

  li   t1, 2000
1:
  addi t1, t1, -1
  andi t2, t1, 3
  bnez t2, 2f
  nop
2:
  bnez t1, 1b
3:
  wfi
  j    3b

peer_pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
4: j    4b
#endif

#ifdef SMT_BALANCE
  .section .data
  .align 6
balance_state:
  .zero 128
balance_active:
#ifdef SMT_BALANCE_SOLO
  .dword (1 << SMT_BALANCE_SOLO)
#else
  .dword 3
#endif
#endif
#ifdef SMT_LRSC_DEP
  .section .data
  .align 6
lr_words:
  .dword 2
  .zero 56
  .dword 2
  .zero 56
lr_seen:
  .word 0
#endif
#ifdef SMT_BOOT_RENDEZVOUS
  .section .data
  .align 6
rendezvous:
  .word 0, 0, 0, 0, 0
#endif

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
