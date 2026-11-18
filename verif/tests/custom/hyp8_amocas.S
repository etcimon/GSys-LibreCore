# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# hyp8 rfix131a: Zacas AMOCAS.W/D/Q directed test (RV64, single-hart).
# Requires CVA6Cfg.RVZacas=1. STRICT: an illegal AMOCAS traps to a distinct
# tohost code (0xE1) so "Zacas not implemented" is separable from a wrong
# compare result. AMOCAS.Q additionally proves the 2-phase register-pair
# gather (rd/rd+1 expected, rs2/rs2+1 new) on issue hardware.
#
# Encodings (raw .word; the pinned GCC has no zacas mnemonic):
#   amocas.d a0, a1, (a2)  = 0x28B6352F   funct5=00101 funct3=011
#   amocas.w a0, a1, (a2)  = 0x28B6252F   funct5=00101 funct3=010
#   amocas.q a0, a2, (a6)  = 0x28C8452F   funct5=00101 funct3=100
# Semantics: rd = expected (also dest), rs2 = new, rs1 = addr.
#   mem==expected -> mem:=new, rd:=old ; mem!=expected -> mem kept, rd:=old.
.option norvc
.section .text.init
.globl _start
_start:
  la    t0, trap
  csrw  mtvec, t0
  fence

# ================================================================ AMOCAS.D
# ---- D success: mem==expected -> swap, rd gets old ----
  li    t0, 0x1111111111111111
  sd    t0, 0(sp)
  li    a0, 0x1111111111111111      # expected
  li    a1, 0x2222222222222222      # new
  mv    a2, sp                      # addr
  .word 0x28B6352F                  # amocas.d a0, a1, (a2)
  li    t1, 0x1111111111111111
  bne   a0, t1, fail_d_ret          # rd must be old mem value
  ld    t2, 0(sp)
  li    t3, 0x2222222222222222
  bne   t2, t3, fail_d_mem          # mem must be swapped

# ---- D mismatch: mem!=expected -> keep mem, rd gets old ----
  li    t0, 0x3333333333333333
  sd    t0, 16(sp)
  li    a0, 0xDEADBEEFCAFEBABE      # expected (wrong)
  li    a1, 0x4444444444444444      # new
  addi  a2, sp, 16
  .word 0x28B6352F
  li    t1, 0x3333333333333333
  bne   a0, t1, fail_d_ret2         # rd = actual old mem
  ld    t2, 16(sp)
  bne   t2, t1, fail_d_mem2         # mem unchanged

# ================================================================ AMOCAS.W
# ---- W success ----
  li    t0, 0x5555AAAA
  sw    t0, 32(sp)
  li    a0, 0x5555AAAA               # expected (zero-extended into rd path)
  li    a1, 0x12345678               # new
  addi  a2, sp, 32
  .word 0x28B6252F                  # amocas.w a0, a1, (a2)
  li    t1, 0x5555AAAA
  bne   a0, t1, fail_w_ret          # rd = sign-extended? check below
  lw    t2, 32(sp)
  li    t3, 0x12345678
  bne   t2, t3, fail_w_mem

# ---- W mismatch: CAS returns old word; mem kept ----
  li    t0, 0x80000001               # old word has bit31 set
  sw    t0, 36(sp)
  li    a0, 0x00000002               # expected (wrong -> mismatch)
  li    a1, 0x99999999
  addi  a2, sp, 36
  .word 0x28B6252F
  # low 32 of rd must be the actual old word (CAS return correctness)
  slli  t1, a0, 32
  srli  t1, t1, 32
  li    t2, 0x80000001
  bne   t1, t2, fail_w_retl
  # architectural .W result is sign-extended to XLEN
  li    t1, 0xFFFFFFFF80000001
  bne   a0, t1, fail_w_sext
  lw    t2, 36(sp)
  li    t3, 0x80000001
  bne   t2, t3, fail_w_mem2         # mem unchanged

# ================================================================ AMOCAS.Q
  andi sp, sp, -16
  addi sp, sp, -64                  # fresh 16B-aligned quad slot below frame
  # ---- Q success: 128-bit compare+swap ----
  li    t0, 0x1111111111111111
  li    t1, 0x2222222222222222
  sd    t0, 0(sp)
  sd    t1, 8(sp)                   # mem = {hi=0x2222.., lo=0x1111..}
  li    a0, 0x1111111111111111      # expected lo
  li    a1, 0x2222222222222222      # expected hi
  li    a2, 0xAAAAAAAAAAAAAAAA      # new lo
  li    a3, 0xBBBBBBBBBBBBBBBB      # new hi
  mv    a6, sp                      # addr (16B aligned)
  .word 0x28C8452F                  # amocas.q a0, a2, (a6)
  li    t0, 0x1111111111111111
  li    t1, 0x2222222222222222
  bne   a0, t0, fail_q_ret
  bne   a1, t1, fail_q_ret          # rd pair = old mem
  ld    t2, 0(sp)
  ld    t3, 8(sp)
  li    t4, 0xAAAAAAAAAAAAAAAA
  li    t5, 0xBBBBBBBBBBBBBBBB
  bne   t2, t4, fail_q_mem
  bne   t3, t5, fail_q_mem

  # ---- Q mismatch: keep 128-bit mem ----
  li    t0, 0x3333333333333333
  li    t1, 0x4444444444444444
  sd    t0, 16(sp)
  sd    t1, 24(sp)
  li    a0, 0xDEADBEEFCAFEBABE
  li    a1, 0x0123456789ABCDEF
  li    a2, 0x5555555555555555
  li    a3, 0x6666666666666666
  addi  a6, sp, 16
  .word 0x28C8452F
  li    t0, 0x3333333333333333
  li    t1, 0x4444444444444444
  bne   a0, t0, fail_q_ret2
  bne   a1, t1, fail_q_ret2
  ld    t2, 16(sp)
  ld    t3, 24(sp)
  bne   t2, t0, fail_q_mem2
  bne   t3, t1, fail_q_mem2

# ---- all passed ----
  li    t0, 1
  la    t1, tohost
  sw    t0, 0(t1)
done:
  j     done

# distinct fail codes: (2*section+1) style; Q failures tagged high
fail_d_ret:   li t0, 11; j report
fail_d_mem:   li t0, 13; j report
fail_d_ret2:  li t0, 15; j report
fail_d_mem2:  li t0, 17; j report
fail_w_ret:   li t0, 19; j report
fail_w_mem:   li t0, 21; j report
fail_w_retl:  li t0, 35; j report
fail_w_sext:  li t0, 23; j report
fail_w_mem2:  li t0, 25; j report
fail_q_ret:   li t0, 27; j report
fail_q_mem:   li t0, 29; j report
fail_q_ret2:  li t0, 31; j report
fail_q_mem2:  li t0, 33; j report
report:
  la    t1, tohost
  sw    t0, 0(t1)
  j     done

# illegal instruction (Zacas not implemented / bad encoding) -> distinct code
trap:
  li    t0, 0xE1
  la    t1, tohost
  sw    t0, 0(t1)
trap_spin:
  j     trap_spin

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
