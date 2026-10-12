# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# CBO under contention (T23, plan item 4: directed COH_FILTERED breadth).
# mc_cbo_ewt exercises cbo.inval / clean / flush / zero on a QUIET line. Here
# three cores (harts 2, 4, 6) keep writing their own dword slots of LINE
# (plain ld / addi / sd, ITERS times each) while hart 0 runs cbo.clean and
# cbo.flush on that very line in a loop until every writer is done. Each CMO
# travels the cluster CMO sideband to every level and every core
# (mc_cbo_ewt): a clean that races a writer's store, or a flush whose
# invalidation lands between a writer's load and its store, must still leave
# every slot at ITERS -- cbo.clean / cbo.flush are write-backs, never
# discards. (cbo.inval IS a discard by definition and is not used here: on a
# write-through L1 with a write-back L2 it may legally drop a dirty L2 line.)
#
# Hart 0 also reads slot 0 of LINE between CMOs so its own L1 keeps
# re-fetching the contended line (a fourth sharer that never writes).
#
# Fail codes (tohost): 9 a slot != ITERS after the writers are done (the
# defect), 13 hart 0's CMO loop ran out of its bound before every DONE
# (a writer never started or never finished: not a coherence verdict by
# itself -- raise CMO_ITERS or read the trace).
# Trap: 32+((mcause<<1)|1). ORACLE_NEGATIVE expects tohost 3.
#
# Needs NrCores=4 (hart mask 1111 with SMT2). M-mode: cbo.clean / cbo.flush
# need no menvcfg enable.

#ifndef ITERS
#define ITERS 1500
#endif
#ifndef CMO_ITERS
#define CMO_ITERS 200000
#endif
#ifndef NR_WRITERS
#define NR_WRITERS 3
#endif
  .equ CLINT_MSIP, 0x02000000
  .equ LINE,     0x800a0000     # slot w at +8*w (w = 1..3), +0 is hart 0's read word
  .equ GO,       0x800a0100
  .equ DONE,     0x800a0200     # + writer*64
  .equ SPIN_TO,  400000

# CBO encodings (Zicbom, MISC-MEM major 0001111, funct3=010):
#   inval imm12=0, clean imm12=1, flush imm12=2.
.macro CBO_CLEAN rs
  .4byte (1 << 20) | (\rs << 15) | (2 << 12) | 0x0f
.endm
.macro CBO_FLUSH rs
  .4byte (2 << 20) | (\rs << 15) | (2 << 12) | 0x0f
.endm

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  andi t1, t0, 1
  bnez t1, park                 # SMT sibling harts park
  srli s0, t0, 1                # s0 = core index (1..3 write, 0 cleans)
  li   t1, NR_WRITERS + 1
  bgeu s0, t1, park
  bnez s0, writer

  # ---- hart 0: clear, release the writer cores, then clean/flush the line ----
  li   s1, LINE
  sd   zero, 0(s1)
  sd   zero, 8(s1)
  sd   zero, 16(s1)
  sd   zero, 24(s1)
  li   t0, GO
  sd   zero, 0(t0)
  li   t0, DONE
  li   t2, NR_WRITERS
1:
  sd   zero, 0(t0)
  addi t0, t0, 64
  addi t2, t2, -1
  bnez t2, 1b
  fence rw, rw
  li   t0, GO
  li   t1, 1
  sd   t1, 0(t0)
  fence rw, rw
  li   t0, CLINT_MSIP
  li   t2, 1
2:                              # msip for harts 2, 4, 6
  li   t3, NR_WRITERS + 1
  bgeu t2, t3, 3f
  slli t3, t2, 3
  add  t3, t3, t0
  sw   t1, 0(t3)
  addi t2, t2, 1
  j    2b
3:
  li   a0, LINE
  li   s2, CMO_ITERS
4:                              # clean, read, flush, read -- until every DONE
  CBO_CLEAN 10
  ld   t1, 0(a0)
  CBO_FLUSH 10
  ld   t1, 0(a0)
  jal  ra, all_done
  bnez t1, 5f
  addi s2, s2, -1
  bnez s2, 4b
  j    fail_cmo_bound
5:
  fence rw, rw
  li   t3, LINE
  li   t4, NR_WRITERS
  li   t1, ITERS
6:
  addi t3, t3, 8
  ld   t0, 0(t3)
  bne  t0, t1, fail_slot
  addi t4, t4, -1
  bnez t4, 6b
#ifdef ORACLE_NEGATIVE
  li   a0, 3
#else
  li   a0, 1
#endif
  j    tohost_store

# t1 = 1 when every DONE[w] is set (hart 0 only; clobbers t2 t3 t4)
all_done:
  li   t3, DONE
  li   t4, NR_WRITERS
7:
  ld   t2, 0(t3)
  beqz t2, 8f
  addi t3, t3, 64
  addi t4, t4, -1
  bnez t4, 7b
  li   t1, 1
  ret
8:
  li   t1, 0
  ret

  # ---- writers: wait GO, hammer my slot, DONE ----
writer:
  li   t0, GO
  li   t2, SPIN_TO
9:
  ld   t1, 0(t0)
  bnez t1, 10f
  addi t2, t2, -1
  bnez t2, 9b
  j    park
10:
  li   s1, LINE
  slli t0, s0, 3
  add  s1, s1, t0               # my slot (+8*core)
  li   s2, ITERS
11:
  ld   t1, 0(s1)
  addi t1, t1, 1
  sd   t1, 0(s1)
  addi s2, s2, -1
  bnez s2, 11b
  fence rw, rw
  li   t0, DONE
  addi t1, s0, -1
  slli t1, t1, 6
  add  t0, t0, t1
  li   t1, 1
  sd   t1, 0(t0)
  fence rw, rw
  j    park

fail_slot:
  li   a0, 9
  j    tohost_store
fail_cmo_bound:
  li   a0, 13
  j    tohost_store
tohost_store:
  la   t0, tohost
  sw   a0, 0(t0)
12: j 12b

park:
  wfi
  j    park

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
13: j 13b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
