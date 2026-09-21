# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Minimal staged probe for the OoO memory-path hang seen with ooo_mem_dep on
# g6lc64_ooo_int (integer-only, no FP anywhere). Each stage adds exactly one
# construct, so the first stage that stops completing names the mechanism
# instead of leaving a whole test to bisect.
#
#   -DSTAGE=1  store only, never read back      -> does a store retire at all?
#   -DSTAGE=2  store, then load a DIFFERENT line -> load path, no forwarding
#   -DSTAGE=3  store, then load the SAME address -> store-to-load forwarding
#   -DSTAGE=4  two stores, load the older one    -> age ordering across stores
#   -DSTAGE=5  store/load inside a loop          -> repeated LSQ allocate/free
#
# Every stage is self-checking and exits 0 on pass, 1 on fail, so a hang is
# distinguishable from a wrong result.

#ifndef STAGE
#define STAGE 3
#endif

  .globl main
main:
  addi sp, sp, -64

#if STAGE == 1
  # Store alone. If this hangs, the store never drains and nothing else matters.
  li   t0, 0x1111222233334444
  sd   t0, 0(sp)

#elif STAGE == 2
  # Load a line the store did not touch: exercises the load path without
  # requiring any store-to-load dependence to resolve.
  li   t0, 0x1111222233334444
  sd   t0, 0(sp)
  ld   t1, 32(sp)          # different line, value unchecked

#elif STAGE == 3
  # The dependent case: the load must observe the older store.
  li   t0, 0x1111222233334444
  sd   t0, 0(sp)
  ld   t1, 0(sp)
  bne  t0, t1, fail

#elif STAGE == 4
  # Two live stores, then a load matching the OLDER one: the load must not take
  # the younger store's data.
  li   t0, 0xAAAAAAAABBBBBBBB
  li   t1, 0xCCCCCCCCDDDDDDDD
  sd   t0, 8(sp)
  sd   t1, 16(sp)
  ld   t2, 8(sp)
  bne  t0, t2, fail

#elif STAGE == 5
  # Repeated allocate/free of LSQ entries.
  li   a1, 0
  li   a2, 16
  li   t0, 0
2:
  add  t0, t0, a1
  sd   t0, 32(sp)
  ld   t1, 32(sp)
  bne  t0, t1, fail
  addi a1, a1, 1
  addi a2, a2, -1
  bnez a2, 2b
  li   a0, 120
  bne  t0, a0, fail
#elif STAGE == 6
  # Stage 4 compared two registers, so either could have been the corrupted
  # one. Check each against a freshly materialised immediate and report which:
  #   exit 2 = the STORED register was clobbered (t0)
  #   exit 3 = the LOADED value is wrong (t2)
  li   t0, 0xAAAAAAAABBBBBBBB
  li   t1, 0xCCCCCCCCDDDDDDDD
  sd   t0, 8(sp)
  sd   t1, 16(sp)
  ld   t2, 8(sp)
  li   t4, 0xAAAAAAAABBBBBBBB
  bne  t0, t4, fail_t0
  bne  t2, t4, fail_t2

#elif STAGE == 7
  # Same shape as stage 4 but the two stores are far apart, in different cache
  # lines. If this passes while stage 4 fails, proximity matters; if it fails
  # too, the fault is simply "two live stores".
  li   t0, 0xAAAAAAAABBBBBBBB
  li   t1, 0xCCCCCCCCDDDDDDDD
  sd   t0, 0(sp)
  sd   t1, 56(sp)
  ld   t2, 0(sp)
  li   t4, 0xAAAAAAAABBBBBBBB
  bne  t0, t4, fail_t0
  bne  t2, t4, fail_t2
#elif STAGE == 8
  # Stage 4 exactly, plus ONE independent instruction between the load and its
  # consumer. Stage 6/7 passed only because a multi-instruction `li` sat in that
  # gap, so the question is how much delay the consumer needs: if one nop is
  # enough, the load result is being announced exactly one cycle early.
  li   t0, 0xAAAAAAAABBBBBBBB
  li   t1, 0xCCCCCCCCDDDDDDDD
  sd   t0, 8(sp)
  sd   t1, 16(sp)
  ld   t2, 8(sp)
  nop
  bne  t0, t2, fail_t2

#elif STAGE == 9
  # Two independent instructions in the gap.
  li   t0, 0xAAAAAAAABBBBBBBB
  li   t1, 0xCCCCCCCCDDDDDDDD
  sd   t0, 8(sp)
  sd   t1, 16(sp)
  ld   t2, 8(sp)
  nop
  nop
  bne  t0, t2, fail_t2

#elif STAGE == 11
  # Loop with NO memory at all. Does a taken backward branch work under OoO?
  li   a2, 16
  li   t0, 0
3:
  addi t0, t0, 1
  addi a2, a2, -1
  bnez a2, 3b
  li   a0, 16
  bne  t0, a0, fail_t2

#elif STAGE == 12
  # Loop with a STORE only (no load): store retire inside a loop.
  li   a2, 16
  li   t0, 0
4:
  addi t0, t0, 1
  sd   t0, 32(sp)
  addi a2, a2, -1
  bnez a2, 4b
  li   a0, 16
  bne  t0, a0, fail_t2

#elif STAGE == 13
  # Loop with a LOAD only (no store in the loop): load completion in a loop.
  li   t0, 7
  sd   t0, 32(sp)
  li   a2, 16
5:
  ld   t1, 32(sp)
  addi a2, a2, -1
  bnez a2, 5b
  li   a0, 7
  bne  t1, a0, fail_t2

#elif STAGE == 14
  # Stage 5 shape with only TWO iterations. The IQ age gate orders a load
  # against older stores with a CIRCULAR trans_id compare
  # ((s - commit_ptr) < (load.tid - commit_ptr)); a long loop cycles trans_ids
  # through wrap, a short one does not. If 2 iterations pass where 16 hangs,
  # the ordering compare across wrap is implicated rather than the
  # store-to-load dependence itself.
  li   a1, 0
  li   a2, 2
  li   t0, 0
6:
  add  t0, t0, a1
  sd   t0, 32(sp)
  ld   t1, 32(sp)
  bne  t0, t1, fail_t2
  addi a1, a1, 1
  addi a2, a2, -1
  bnez a2, 6b

#elif STAGE == 16
  # Three iterations: pins the threshold between the passing 2 and hanging 4.
  li   a1, 0
  li   a2, 3
  li   t0, 0
8:
  add  t0, t0, a1
  sd   t0, 32(sp)
  ld   t1, 32(sp)
  bne  t0, t1, fail_t2
  addi a1, a1, 1
  addi a2, a2, -1
  bnez a2, 8b

#elif STAGE == 15
  # Four iterations: brackets where it turns over, if 2 passes and 16 hangs.
  li   a1, 0
  li   a2, 4
  li   t0, 0
7:
  add  t0, t0, a1
  sd   t0, 32(sp)
  ld   t1, 32(sp)
  bne  t0, t1, fail_t2
  addi a1, a1, 1
  addi a2, a2, -1
  bnez a2, 7b

#elif STAGE == 17
  li   t0, 0x111
  li   t6, 0x222
  sd   t0, 0(sp)
  fence rw, rw
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0
  add  t3, sp, t3
  ld   t4, 0(t3)
  sd   t6, 0(sp)
#ifdef MEM_ORDER_NEGATIVE
  xori t0, t0, 1
#endif
  bne  t4, t0, fail_t2
  ld   t5, 0(sp)
  bne  t5, t6, fail_t2

#elif STAGE == 18
  li   t0, 0x111
  li   t6, 0x333
  sd   t0, 0(sp)
  fence rw, rw
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0
  addi t4, t3, 0x222
  sd   t4, 0(sp)
  sd   t6, 0(sp)
  fence rw, rw
  ld   t5, 0(sp)
#ifdef MEM_ORDER_NEGATIVE
  xori t6, t6, 1
#endif
  bne  t5, t6, fail_t2

#elif STAGE == 19
  li   t0, 0x1122334455667788
  li   t6, 0xEE
  sd   t0, 0(sp)
  fence rw, rw
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0
  add  t3, sp, t3
  ld   t4, 0(t3)
  sb   t6, 0(sp)
#ifdef MEM_ORDER_NEGATIVE
  xori t0, t0, 1
#endif
  bne  t4, t0, fail_t2

#elif STAGE == 20
  # Converse of stage 17: the age filter must not OVER-filter. The older store's
  # DATA is late, so the younger same-address load has to wait for it rather than
  # read around it. A filter that wrongly excluded this store would return the
  # stale pre-existing value instead of stalling, which stages 17-19 cannot see.
  li   t5, 0xDEAD
  sd   t5, 0(sp)
  fence rw, rw
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0
  addi t4, t3, 0x444
  sd   t4, 0(sp)
  ld   t6, 0(sp)
#ifdef MEM_ORDER_NEGATIVE
  xori t4, t4, 1
#endif
  bne  t6, t4, fail_t2

#elif STAGE == 21
  # Capacity interaction: the speculative store queue is small and drains only on
  # commit, and commit is in program order. If younger stores whose data resolves
  # first can fill it while the OLDEST store is still waiting to post, that store
  # can never post, so nothing can commit and nothing can drain. Six stores
  # against a four-deep queue, oldest one data-delayed.
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0
  addi t4, t3, 0x501
  sd   t4, 0(sp)
  li   t5, 0x502
  sd   t5, 8(sp)
  li   t5, 0x503
  sd   t5, 16(sp)
  li   t5, 0x504
  sd   t5, 24(sp)
  li   t5, 0x505
  sd   t5, 32(sp)
  li   t5, 0x506
  sd   t5, 40(sp)
  fence rw, rw
  ld   t6, 0(sp)
  li   t0, 0x501
#ifdef MEM_ORDER_NEGATIVE
  xori t0, t0, 1
#endif
  bne  t6, t0, fail_t2
  ld   t6, 40(sp)
  li   t0, 0x506
  bne  t6, t0, fail_t2

#elif STAGE == 22
  # Stage 21 reordered five younger stores but the queue is eight deep, so it
  # never reached capacity. Ten outstanding stores with the oldest data-delayed
  # pushes past DEPTH_SPEC: if younger stores can occupy every slot while the
  # oldest still cannot post, in-order commit has nothing to drain. The younger
  # stores also share one address, so their order decides the final value.
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0
  addi t4, t3, 0x601
  sd   t4, 0(sp)
  li   t5, 0x602
  sd   t5, 8(sp)
  li   t5, 0x603
  sd   t5, 8(sp)
  li   t5, 0x604
  sd   t5, 8(sp)
  li   t5, 0x605
  sd   t5, 8(sp)
  li   t5, 0x606
  sd   t5, 8(sp)
  li   t5, 0x607
  sd   t5, 8(sp)
  li   t5, 0x608
  sd   t5, 8(sp)
  li   t5, 0x609
  sd   t5, 8(sp)
  li   t5, 0x60A
  sd   t5, 8(sp)
  fence rw, rw
  ld   t6, 0(sp)
  li   t0, 0x601
#ifdef MEM_ORDER_NEGATIVE
  xori t0, t0, 1
#endif
  bne  t6, t0, fail_t2
  ld   t6, 8(sp)
  li   t0, 0x60A
  bne  t6, t0, fail_t2

#elif STAGE == 23
  # AMO ordering against out-of-order neighbours. An AMO does not go through the
  # store buffer: amo_buffer holds it and the request only fires when the store
  # buffer has drained AND the AMO is at commit. Three obligations at once:
  #   - the AMO observes an older store whose data resolved late,
  #   - its return value is that store's value, not stale memory,
  #   - a younger load observes the AMO's effect, not the pre-AMO value.
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0
  addi t4, t3, 0x700
  sd   t4, 0(sp)
  li   t5, 5
  amoadd.d t6, t5, (sp)
  ld   t0, 0(sp)
  li   t1, 0x700
#ifdef MEM_ORDER_NEGATIVE
  xori t1, t1, 1
#endif
  bne  t6, t1, fail_t2
  li   t1, 0x705
  bne  t0, t1, fail_t2

#elif STAGE == 24
  # Discriminator for stage 23's trace mismatch. There the AMO returned the right
  # old value but its LOGGED memory effect was the pre-add value, while the
  # program's own read-back still saw the added value. Either memory is wrong and
  # the read-back was satisfied by a stale forward, or memory is right and the
  # RVFI memory-effect field for AMO is misreported.
  # A second AMO settles it: an AMO reads memory at commit and cannot be
  # satisfied by a forward, so its returned old value is authoritative.
  li   t0, 0x800
  sd   t0, 0(sp)
  fence rw, rw
  li   t5, 7
  amoadd.d t6, t5, (sp)      # memory should become 0x807, t6 = 0x800
  fence rw, rw
  amoadd.d t4, x0, (sp)      # adds nothing; t4 = authoritative memory content
  li   t1, 0x800
  bne  t6, t1, fail_t2
  li   t1, 0x807
#ifdef MEM_ORDER_NEGATIVE
  xori t1, t1, 1
#endif
  bne  t4, t1, fail_t2
  ld   t3, 0(sp)
  bne  t3, t1, fail_t2

#elif STAGE == 25
  # LR/SC against a still-speculative older store. LR takes the load path, so it
  # is subject to the same forwarding age rules as an ordinary load, while SC
  # goes to the AMO buffer and resolves at commit. Obligations:
  #   - LR observes the older store whose data resolved late,
  #   - the SC succeeds (its reservation is not broken by that older store),
  #   - memory ends with the SC's value.
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0
  # 0x900 exceeds addi's signed 12-bit immediate, so materialise it with li and
  # add the slow zero to keep the store's data dependent on the divu.
  li   t4, 0x900
  add  t4, t4, t3
  sd   t4, 0(sp)
  lr.d t5, (sp)
  li   t6, 0x901
  sc.d t0, t6, (sp)
  ld   t1, 0(sp)
  li   t2, 0x900
#ifdef MEM_ORDER_NEGATIVE
  xori t2, t2, 1
#endif
  bne  t5, t2, fail_t2
  bnez t0, fail_t2
  li   t2, 0x901
  bne  t1, t2, fail_t2

#elif STAGE == 26
  # A failed SC must leave memory untouched. A same-hart store between the LR and
  # the SC makes this an unconstrained LR/SC sequence, so the ISA permits the SC
  # to succeed OR fail; asserting one outcome would over-specify. Assert instead
  # the invariant that holds either way: the SC's reported result and the memory
  # content must agree. This is what catches an SC that writes while reporting
  # failure, which is the case RVFI previously could not have shown.
  li   t0, 0xA00
  sd   t0, 0(sp)
  fence rw, rw
  lr.d t1, (sp)
  li   t2, 0xA01
  sd   t2, 0(sp)
  li   t3, 0xA02
  sc.d t4, t3, (sp)
  ld   t5, 0(sp)
  beqz t4, 1f
  # reported failure: memory must still hold the intervening store's value
  li   t6, 0xA01
  bne  t5, t6, fail_t2
  j    2f
1:
  # reported success: memory must hold the SC's value
  li   t6, 0xA02
  bne  t5, t6, fail_t2
2:
  li   t6, 0xA00
#ifdef MEM_ORDER_NEGATIVE
  xori t6, t6, 1
#endif
  bne  t1, t6, fail_t2

#elif STAGE == 27
  # Discriminator for stage 26's hang. There the instruction that never retires
  # is the plain store FOLLOWING a retired lr.d. Repeat with the store aimed at
  # an unrelated address: if it still hangs the fault is in the store path after
  # an AMO (amo_buffer drain / store-unit readiness), not in reservation logic.
  li   t0, 0xB00
  sd   t0, 0(sp)
  fence rw, rw
  lr.d t1, (sp)
  li   t2, 0xB01
  sd   t2, 16(sp)
  ld   t3, 16(sp)
  li   t4, 0xB00
#ifdef MEM_ORDER_NEGATIVE
  xori t4, t4, 1
#endif
  bne  t1, t4, fail_t2
  li   t4, 0xB01
  bne  t3, t4, fail_t2

#elif STAGE == 28
  # Stage 27 without the fence. The store-unit probe showed the LR pushed into the
  # depth-1 AMO buffer twice: once at first issue, then again after the fence's
  # flush cleared it, and the second entry is never popped so st_ready stays low
  # forever. If removing the fence removes the hang, the flush/re-push is
  # implicated rather than LR handling on its own.
  li   t0, 0xC00
  sd   t0, 8(sp)
  lr.d t1, (sp)
  li   t2, 0xC01
  sd   t2, 16(sp)
  ld   t3, 16(sp)
  li   t4, 0xC01
#ifdef MEM_ORDER_NEGATIVE
  xori t4, t4, 1
#endif
  bne  t3, t4, fail_t2

#elif STAGE == 29
  # Store after a NON-LR AMO. The dual-hart lock test stalls on OoO, and its
  # critical section is exactly amoswap-then-store. lr_sc_pair_q is set only by
  # an LR, so if this hangs the store-after-AMO block is wider than the LR/SC
  # window; if it passes, the lock stall is dual-hart/scheduler-specific.
  li   t0, 1
  li   t1, 0
  sd   t1, 0(sp)
  fence rw, rw
  amoswap.w.aq t2, t0, (sp)
  li   t3, 0xD01
  sd   t3, 16(sp)
  ld   t4, 16(sp)
  li   t5, 0xD01
#ifdef MEM_ORDER_NEGATIVE
  xori t5, t5, 1
#endif
  bne  t4, t5, fail_t2

#elif STAGE == 30
  # Younger CSR ahead of an older FLU consumer. The two-hart lock stall shows
  # flu_ready=0 forever with a full scoreboard, and both harts stuck in a
  # prologue that contains csrw/csrr. ALU, branch and CSR share the FLU, and a
  # CSR resolves at commit, so if the IQ may issue a younger CSR before an older
  # ALU op that is still waiting for its operand, the CSR holds the FLU until it
  # commits while the older op cannot execute, cannot retire, and therefore never
  # lets the CSR reach the commit head.
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  add  t4, t3, t3
  csrr t5, mhartid
  csrw mscratch, t5
  csrr t6, mscratch
  andi t4, t4, 0
  add  t4, t4, t6
#ifdef MEM_ORDER_NEGATIVE
  addi t4, t4, 1
#endif
  bnez t4, fail_t2

#elif STAGE == 31
  # Both IQ admission rules at once, at queue capacity. Stores must issue in
  # program order (stage22's rule) while CSRs may issue only at the commit head
  # (the FLU rule). Interleaving them with a delayed OLDEST store puts both gates
  # live simultaneously: the CSRs cannot advance until they are oldest, and they
  # cannot become oldest until the stalled older store drains. If the two rules
  # compose badly this deadlocks rather than merely slowing down.
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0
  addi t4, t3, 0x401
  sd   t4, 0(sp)              # oldest store, data arrives late
  csrr t5, mhartid
  li   t6, 0x402
  sd   t6, 8(sp)
  csrw mscratch, t5
  li   t6, 0x403
  sd   t6, 16(sp)
  csrr t0, mscratch
  li   t6, 0x404
  sd   t6, 24(sp)
  csrr t1, mhartid
  li   t6, 0x405
  sd   t6, 32(sp)
  ld   t2, 0(sp)
  li   t6, 0x401
#ifdef MEM_ORDER_NEGATIVE
  xori t6, t6, 1
#endif
  bne  t2, t6, fail_t2
  ld   t2, 32(sp)
  li   t6, 0x405
  bne  t2, t6, fail_t2
  bne  t0, t1, fail_t2

#elif STAGE == 32 || STAGE == 33
  csrr s1, mtvec
  la   t0, .Lmisalign_handler
  csrw mtvec, t0
  li   a4, 0
  li   a5, 0x55
#if STAGE == 33
  li   t0, 0x7fffffffffffffff
  li   t1, 3
  divu t2, t0, t1
  bnez t2, .Lmisalign_check
#endif
  .option push
  .option norvc
.Lmisalign_load:
  lw   a5, 6(sp)
  .option pop
.Lmisalign_check:
#if STAGE == 32
  li   t0, 1
#else
  li   t0, 0
#endif
#ifdef MEM_ORDER_NEGATIVE
  xori t0, t0, 1
#endif
  bne  a4, t0, fail_trap_count
  li   t0, 0x55
  bne  a5, t0, fail_trap_wrote_rd
  csrw mtvec, s1
  j    .Lmisalign_done
  .balign 4
.Lmisalign_handler:
  csrr t6, mcause
  li   t5, 4
  bne  t6, t5, fail_trap_cause
  # mtval is only written when the target configures TvalEn, so a zero report is
  # legal here. Check the address only when one was reported, rather than making
  # the test depend on a field the envelope does not require.
  csrr t4, mtval
  beqz t4, .Lmisalign_tval_absent
  addi t5, sp, 6
  bne  t4, t5, fail_trap_tval
.Lmisalign_tval_absent:
  csrr t5, mepc
  la   t6, .Lmisalign_load
  bne  t5, t6, fail_trap_mepc
  addi a4, a4, 1
  addi t5, t5, 4
  csrw mepc, t5
  mret
.Lmisalign_done:

#elif STAGE == 34
  # Stage32 with exactly ONE difference: the two post-trap consumer branches
  # share a target instead of having distinct ones. Stage32 (distinct targets)
  # passes; the frozen ELF that resumed at the sequential PC instead of mtvec had
  # both of its consumer branches pointing at one label. If this stage fails
  # while stage32 passes, that shared-target geometry is the co-factor. If it
  # passes, the aliasing explanation is dead and must be replaced, not weakened.
  #
  # The load is forced to an 8-byte boundary so the geometry of the original is
  # reproduced: a 4-byte faulting load, a 2-byte co-issued op, then a 4-byte
  # branch that straddles the next fetch-window boundary.
  csrr s1, mtvec
  la   t0, .Lalias_handler
  csrw mtvec, t0
  li   a4, 0
  li   a5, 0x55
  .balign 8
.Lalias_load:
  .option push
  .option norvc
  lw   a5, 6(sp)
  .option pop
  li   t0, 1
  bne  a4, t0, fail_alias
  li   t0, 0x55
  bne  a5, t0, fail_alias
  csrw mtvec, s1
  j    .Lalias_done
  .balign 4
.Lalias_handler:
  csrr t6, mcause
  li   t5, 4
  bne  t6, t5, fail_trap_cause
  csrr t5, mepc
  la   t6, .Lalias_load
  bne  t5, t6, fail_trap_mepc
  addi a4, a4, 1
  addi t5, t5, 4
  csrw mepc, t5
  mret
.Lalias_done:

#elif STAGE == 10
  # Stage 4 shape with the SECOND store removed, but the same addresses and the
  # same zero-gap consumer. Isolates "two live stores" from "adjacent consumer".
  li   t0, 0xAAAAAAAABBBBBBBB
  sd   t0, 8(sp)
  ld   t2, 8(sp)
  bne  t0, t2, fail_t2
#endif

  addi sp, sp, 64
  li   a0, 0
  jal  exit

fail_t0:
  addi sp, sp, 64
  li   a0, 2
  jal  exit

fail_t2:
  addi sp, sp, 64
  li   a0, 3
  jal  exit

fail:
  addi sp, sp, 64
  li   a0, 1
  jal  exit

# One exit code per phase, so a misalignment failure names the violated clause
# instead of collapsing five different contracts onto a single verdict.
fail_trap_cause:
  addi sp, sp, 64
  li   a0, 4
  jal  exit

fail_trap_tval:
  addi sp, sp, 64
  li   a0, 5
  jal  exit

fail_trap_mepc:
  addi sp, sp, 64
  li   a0, 6
  jal  exit

fail_trap_count:
  addi sp, sp, 64
  li   a0, 7
  jal  exit

fail_trap_wrote_rd:
  addi sp, sp, 64
  li   a0, 8
  jal  exit

# Shared target for the two consumer branches in the shared-target variant. Its
# own code distinguishes "the shared-target geometry reproduced the failure" from
# a handler-clause failure, which keeps its own codes above.
fail_alias:
  addi sp, sp, 64
  li   a0, 9
  jal  exit
