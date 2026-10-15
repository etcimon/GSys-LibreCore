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

#elif STAGE == 35
  # Older store with a LATE ADDRESS (a divide feeds the base register) and a
  # younger same-address load whose address is known at once. A load allowed
  # past the unresolved store reads the pre-existing value and must be replayed
  # when the store address arrives; the architectural result is the store's.
  li   t5, 0xBEEF
  sd   t5, 0(sp)
  fence rw, rw
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0
  add  t4, sp, t3
  li   t0, 0x1234
  sd   t0, 0(t4)
  ld   t6, 0(sp)
#ifdef MEM_ORDER_NEGATIVE
  xori t0, t0, 1
#endif
  bne  t6, t0, fail_t2

#elif STAGE == 36
  # Same shape, disjoint addresses: the load must NOT wait for the late store
  # and must read its own location's value.
  li   t5, 0xBEEF
  sd   t5, 8(sp)
  fence rw, rw
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0
  add  t4, sp, t3
  li   t0, 0x1234
  sd   t0, 0(t4)
  ld   t6, 8(sp)
#ifdef MEM_ORDER_NEGATIVE
  xori t5, t5, 1
#endif
  bne  t6, t5, fail_t2

#elif STAGE == 37
  # Two CSR accesses with independent ALU work between them: the second CSR
  # must not freeze the ALU behind the first, and both must read/write in order.
  li   t0, 0x40
  csrw mscratch, t0
  li   t1, 7
  addi t1, t1, 1
  csrr t2, mscratch
  addi t1, t1, 1
  li   t3, 0x80
  csrw mscratch, t3
  csrr t4, mscratch
  li   t5, 9
#ifdef MEM_ORDER_NEGATIVE
  addi t1, t1, 1
#endif
  bne  t1, t5, fail
  bne  t2, t0, fail_t2
  bne  t4, t3, fail_t2

#elif STAGE == 38
  # Stage 32 under address translation with a COLD DTLB (T27: the first thing
  # Linux does after `satp` is the unaligned-access probe). Sv39 is switched on
  # for data accesses only through mstatus.MPRV with MPP=S (fetch stays M-mode
  # physical), one identity gigapage covers the program and the stack, and the
  # misaligned `lw` is the first access to that page. The load is granted, the
  # DTLB misses, the request is aborted, the walk fills the TLB, the re-issued
  # load delivers LD_ADDR_MISALIGNED exactly once, with mepc on the load and no
  # write of rd. The bare-metal next-cycle shape of the load_unit assertion was
  # the property this stage distinguishes from the architectural contract.
  csrr s1, mtvec
  la   t0, .Lvm_handler
  csrw mtvec, t0
  # level-2 table: entry 2 = 0x80000000..0xBFFFFFFF, leaf, V|R|W|X|A|D
  la   t1, .Lvm_pt
  li   t2, (0x80000 << 10) | 0xCF
  sd   t2, 16(t1)
  srli t1, t1, 12
  li   t2, 8
  slli t2, t2, 60
  or   t1, t1, t2
  csrw satp, t1
  sfence.vma
  # S-mode data accesses (and the walk) need a matching PMP entry once any
  # entry is implemented: one TOR region over the whole address space, RWX.
  li   t0, -1
  srli t0, t0, 10
  csrw pmpaddr0, t0
  li   t0, 0x0F
  csrw pmpcfg0, t0
  li   a4, 0
  li   a5, 0x55
  li   t0, (1 << 17) | (1 << 11)       # MPRV | MPP = S
  csrs mstatus, t0
  .option push
  .option norvc
.Lvm_load:
  lw   a5, 6(sp)
  .option pop
  li   t0, (1 << 17) | (3 << 11)
  csrc mstatus, t0                      # MPRV off, MPP cleared
  csrw satp, zero
  sfence.vma
  li   t0, 1
#ifdef MEM_ORDER_NEGATIVE
  xori t0, t0, 1
#endif
  bne  a4, t0, fail_trap_count
  li   t0, 0x55
  bne  a5, t0, fail_trap_wrote_rd
  csrw mtvec, s1
  j    .Lvm_done
  .balign 4
.Lvm_handler:
  csrr t6, mcause
  li   t5, 4
  bne  t6, t5, fail_trap_cause
  csrr t4, mtval
  beqz t4, .Lvm_tval_absent
  addi t5, sp, 6
  bne  t4, t5, fail_trap_tval
.Lvm_tval_absent:
  csrr t5, mepc
  la   t6, .Lvm_load
  bne  t5, t6, fail_trap_mepc
  addi a4, a4, 1
  addi t5, t5, 4
  csrw mepc, t5
  mret
  .section .data
  .balign 4096
.Lvm_pt:
  .space 4096
  .text
.Lvm_done:

#elif STAGE == 39
  # Sub-word loads forwarded from a wider, still-speculative store (T27: on
  # g6lc64_ooo OpenSBI's fw_platform_init ends in its fail-wfi while scanning
  # the just-copied FDT with sbi_memchr — byte loads over fresh doubleword
  # stores — where the same payload boots on the server packages). Each byte,
  # halfword and word of a freshly stored doubleword must read back exactly,
  # with no fence between the store and the loads.
  li   t0, 0x1122334455667788
  sd   t0, 0(sp)
  lbu  t1, 0(sp)
  lbu  t2, 1(sp)
  lbu  t3, 2(sp)
  lbu  t4, 3(sp)
  lbu  t5, 4(sp)
  lbu  t6, 5(sp)
  lbu  a1, 6(sp)
  lbu  a2, 7(sp)
  lhu  a3, 2(sp)
  lwu  a4, 4(sp)
  lh   a5, 6(sp)
  li   a6, 0x88
#ifdef MEM_ORDER_NEGATIVE
  xori a6, a6, 1
#endif
  bne  t1, a6, fail_t2
  li   a6, 0x77
  bne  t2, a6, fail_t2
  li   a6, 0x66
  bne  t3, a6, fail_t2
  li   a6, 0x55
  bne  t4, a6, fail_t2
  li   a6, 0x44
  bne  t5, a6, fail_t2
  li   a6, 0x33
  bne  t6, a6, fail_t2
  li   a6, 0x22
  bne  a1, a6, fail_t2
  li   a6, 0x11
  bne  a2, a6, fail_t2
  li   a6, 0x5566
  bne  a3, a6, fail_t2
  li   a6, 0x11223344
  bne  a4, a6, fail_t2
  li   a6, 0x1122
  bne  a5, a6, fail_t2
  # the same scan over a byte store that partially overlays the doubleword
  li   a6, 0xAB
  sb   a6, 3(sp)
  lwu  a7, 0(sp)
  li   a6, 0xAB667788
  bne  a7, a6, fail_t2
  lbu  a7, 3(sp)
  li   a6, 0xAB
  bne  a7, a6, fail_t2

#elif STAGE == 40
  # T27 Linux-boot divergence on g6lc64_ooo, in its exact shape (OpenSBI
  # fdt_next_tag -> fdt_check_prop_offset_): a callee stores a 32-bit result
  # through a pointer into the CALLER's frame (`sw s1, 0(s3)` where s3 =
  # &slot), pops seven callee-saved registers off its own frame, returns, and
  # the caller reloads the slot (`lw a0, -20(s0)`) after a compare/branch. On
  # the boot the RTL load returned the slot's PREVIOUS content (-11) while
  # Spike returned the store's (0x18) — a same-hart RAW through memory across
  # a `ret`, 14 instructions apart. The slot is pre-loaded with the stale
  # value so a missed forward is visible as that value.
  li   t0, -11
  sw   t0, -20(sp)               # the slot's previous content (the earlier call's error code)
  fence rw, rw
  addi s3, sp, -20               # &slot, the pointer the callee stores through
  jal  ra, .Lraw_callee
  li   t0, 3
  bne  t0, t0, fail              # the caller's compare/branch between ret and the load (not taken)
  lw   a0, -20(sp)
  li   t0, 0x18
#ifdef MEM_ORDER_NEGATIVE
  xori t0, t0, 1
#endif
  bne  a0, t0, fail_t2
  j    .Lraw_done
  .balign 4
.Lraw_callee:
  addi sp, sp, -64
  sd   ra, 56(sp)
  sd   s0, 48(sp)
  sd   s1, 40(sp)
  sd   s2, 32(sp)
  sd   s4, 16(sp)
  sd   s5, 8(sp)
  li   s1, 0x15
  addiw s1, s1, 3                # 0x18, computed just before the store (late data)
  andi s1, s1, -4
  sw   s1, 0(s3)                 # the RAW producer: into the caller's slot
  ld   s1, 40(sp)
  li   s2, 9
  ld   ra, 56(sp)
  ld   s0, 48(sp)
  ld   s4, 16(sp)
  ld   s5, 8(sp)
  mv   a0, s2
  ld   s2, 32(sp)
  addi sp, sp, 64
  ret
.Lraw_done:

#elif STAGE == 41
  # Two in-flight stores to the SAME word (the boot's -11 then 0x18 into the
  # fdt offset slot, 90 instructions apart with a call between), no fence, then
  # the load: forwarding must pick the YOUNGEST older store. The first store's
  # data is delayed so it is still unresolved when the second store and the
  # load issue; the earlier stages cover one store or fenced pairs only.
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0
  addi t4, t3, -11
  sw   t4, -20(sp)               # older store, data late (-11)
  addi s3, sp, -20
  jal  ra, .Lraw2_callee         # younger store (0x18) through the pointer, in a callee
  lw   a0, -20(sp)
  li   t0, 0x18
#ifdef MEM_ORDER_NEGATIVE
  xori t0, t0, 1
#endif
  bne  a0, t0, fail_t2
  j    .Lraw2_done
  .balign 4
.Lraw2_callee:
  addi sp, sp, -32
  sd   ra, 24(sp)
  sd   s1, 16(sp)
  li   s1, 0x15
  addiw s1, s1, 3
  andi s1, s1, -4
  sw   s1, 0(s3)
  ld   s1, 16(sp)
  ld   ra, 24(sp)
  addi sp, sp, 32
  ret
.Lraw2_done:

#elif STAGE == 42
  # Stage 41 plus a MISPREDICTED branch between the younger store and the load
  # (the boot has an indirect jump-table dispatch and `beqz` in fdt_next_tag,
  # and the checkpoint census shows restores around the divergence): the
  # branch resolves late (divu-fed), is first-time taken against the static
  # not-taken prediction, so the recovery happens with the 0x18 store already
  # issued and still in flight. The load after the recovery must still
  # forward from that store, not read the slot's old content.
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0                 # 0, late
  addi t4, t3, -11
  sw   t4, -20(sp)               # older store (-11), data late
  addi s3, sp, -20
  jal  ra, .Lraw3_callee
  lw   a0, -20(sp)
  li   t0, 0x18
#ifdef MEM_ORDER_NEGATIVE
  xori t0, t0, 1
#endif
  bne  a0, t0, fail_t2
  j    .Lraw3_done
  .balign 4
.Lraw3_callee:
  addi sp, sp, -32
  sd   ra, 24(sp)
  sd   s1, 16(sp)
  li   s1, 0x15
  addiw s1, s1, 3
  andi s1, s1, -4
  sw   s1, 0(s3)                 # younger store (0x18)
  beqz t3, 1f                    # late-resolving, taken: mispredict + recovery after the store issued
  li   s1, 0x7
  sw   s1, 0(s3)                 # wrong-path store, must leave no trace
1:
  ld   s1, 16(sp)
  ld   ra, 24(sp)
  addi sp, sp, 32
  ret
.Lraw3_done:

#elif STAGE == 43
  # T29: a 4-byte `jal` that STRADDLES two 8-byte fetch windows (offset 6 of an
  # aligned block). On the Linux boot the kernel's `jal .Lsetup_trap_vector` at
  # 0x...1146 was predicted taken (cf=2, target from the instruction scan, no
  # BHT entry) and resolved taken with no mispredict, yet the fetch stream never
  # redirected: the next window (…1150) was consumed, the instruction after the
  # jal in its own window was dropped as "behind a taken branch", and the callee
  # never ran. First encounter (cold predictors), as on the boot.
  li   t0, 0
  li   t1, 0
  li   t2, 0
  .balign 8
  c.nop
  c.nop
  c.nop                          # 6 bytes: the jal starts at offset 6
  .option push
  .option norvc
  jal  ra, .Lstraddle_callee     # bytes 6..9: half in this window, half in the next
  .option pop
  addi t1, t1, 1                 # the instruction after the jal: must run exactly once
  addi t2, t2, 1
  li   t3, 7
#ifdef MEM_ORDER_NEGATIVE
  xori t3, t3, 1
#endif
  bne  t0, t3, fail_t0           # callee skipped
  li   t3, 1
  bne  t1, t3, fail_t2           # instruction after the jal skipped / repeated
  bne  t2, t3, fail_t2
  j    .Lstraddle_done
  .balign 8
.Lstraddle_callee:
  li   t0, 7
  ret
.Lstraddle_done:

#elif STAGE == 44
  # Stage 43 reached the straddling jal sequentially. On the boot it was the
  # TARGET of a `ret` (relocate_enable_mmu returning to 0x...1146): the first
  # fetch window starts at the jal's own address and holds only its first
  # half, the next window completes it. Same shape here: a `ret` lands on the
  # straddling jal.
  li   t0, 0
  li   t1, 0
  li   t2, 0
  jal  ra, .Lstr2_leaf           # the leaf returns onto the straddling jal
  .balign 8
  c.nop
  c.nop
  c.nop
  .option push
  .option norvc
.Lstr2_jal:
  jal  ra, .Lstr2_callee         # offset 6: the ret above lands exactly here
  .option pop
  addi t1, t1, 1
  addi t2, t2, 1
  li   t3, 7
#ifdef MEM_ORDER_NEGATIVE
  xori t3, t3, 1
#endif
  bne  t0, t3, fail_t0
  li   t3, 1
  bne  t1, t3, fail_t2
  bne  t2, t3, fail_t2
  j    .Lstr2_done
  .balign 8
.Lstr2_leaf:
  la   ra, .Lstr2_jal
  ret
  .balign 8
.Lstr2_callee:
  li   t0, 7
  ret
.Lstr2_done:

#elif STAGE == 45
  # Stage 44 plus the boot's last ingredient: the leaf executes a serialising
  # `sfence.vma` right before the (mispredicted) `ret` that lands on the
  # straddling jal — relocate_enable_mmu's `sfence.vma; ret`. The window trace
  # of the boot shows the ret resolved twice (the first resolution outranked by
  # the fence's commit flush), a pending redirect to the ret's target still
  # live when the jal's own taken prediction fired, and the jal's redirect lost.
  li   t0, 0
  li   t1, 0
  li   t2, 0
  jal  ra, .Lstr3_leaf
  .balign 8
  c.nop
  c.nop
  c.nop
  .option push
  .option norvc
.Lstr3_jal:
  jal  ra, .Lstr3_callee
  .option pop
  addi t1, t1, 1
  addi t2, t2, 1
  li   t3, 7
#ifdef MEM_ORDER_NEGATIVE
  xori t3, t3, 1
#endif
  bne  t0, t3, fail_t0
  li   t3, 1
  bne  t1, t3, fail_t2
  bne  t2, t3, fail_t2
  j    .Lstr3_done
  .balign 8
.Lstr3_leaf:
  la   ra, .Lstr3_jal
  sfence.vma
  ret
  .balign 8
.Lstr3_callee:
  li   t0, 7
  ret
.Lstr3_done:

#elif STAGE == 46
  # T29 in its real shape: a predicted-taken jal fetched through INSTRUCTION
  # translation at a virtual address OUTSIDE the physical execute regions. Sv39
  # level-2 table: entry 2 = identity gigapage for 0x80000000 (the test's own
  # PA alias, M-mode stays untranslated anyway), entry 0x1ff = the same physical
  # gigapage at VA 0xffffffffc0000000 (Linux-like high alias). The test enters
  # S-mode at the high alias, where the first `jal` is predicted taken from the
  # instruction scan with a target the PMA filter calls "not fetchable" — on
  # the pre-fix frontend bp_fire stays low, the callee never runs and the
  # instruction after the jal is dropped. Back to M-mode through ecall.
  csrr s1, mtvec
  la   t0, .Lvm2_mhandler
  csrw mtvec, t0
  la   t1, .Lvm2_pt
  li   t2, (0x80000 << 10) | 0xCF
  sd   t2, 16(t1)                      # VPN2 = 2
  li   t3, 2048
  add  t3, t3, t1
  sd   t2, 2040(t3)                    # VPN2 = 0x1ff (offset 4088)
  srli t3, t1, 12
  li   t2, 8
  slli t2, t2, 60
  or   t3, t3, t2
  csrw satp, t3
  sfence.vma
  li   t0, -1
  srli t0, t0, 10
  csrw pmpaddr0, t0
  li   t0, 0x0F
  csrw pmpcfg0, t0
  li   t0, 0
  li   t1, 0
  li   t2, 0
  # S-mode entry at the high alias of .Lvm2_s_entry
  la   t4, .Lvm2_s_entry
  li   t5, 0x80000000
  sub  t4, t4, t5
  li   t5, 0xffffffffc0000000
  add  t4, t4, t5
  csrw mepc, t4
  li   t5, (3 << 11)
  csrc mstatus, t5
  li   t5, (1 << 11)                   # MPP = S
  csrs mstatus, t5
  mret
  .balign 8
.Lvm2_s_entry:
  c.nop
  c.nop
  c.nop
  .option push
  .option norvc
  jal  ra, .Lvm2_callee                # offset 6 of its window, first encounter, VA target
  .option pop
  addi t1, t1, 1
  addi t2, t2, 1
  ecall                                # back to M-mode (cause 9)
.Lvm2_after:
  li   t3, 7
#ifdef MEM_ORDER_NEGATIVE
  xori t3, t3, 1
#endif
  bne  t0, t3, fail_t0                 # callee skipped
  li   t3, 1
  bne  t1, t3, fail_t2                 # instruction after the jal dropped
  bne  t2, t3, fail_t2
  csrw satp, zero
  sfence.vma
  csrw mtvec, s1
  j    .Lvm2_done
  .balign 8
.Lvm2_callee:
  li   t0, 7
  ret
  .balign 4
.Lvm2_mhandler:
  csrr t6, mcause
  li   t5, 9                           # ecall from S
  bne  t6, t5, fail_trap_cause
  la   t5, .Lvm2_after                 # resume in M-mode at the physical alias
  csrw mepc, t5
  li   t5, (3 << 11)
  csrs mstatus, t5                     # MPP = M
  mret
  .section .data
  .balign 4096
.Lvm2_pt:
  .space 4096
  .text
.Lvm2_done:

#elif STAGE == 47
  # T31 candidate (Linux printk on g6lc64_ooo prints `[00000.     0]` and a
  # decimal where `%llx` was asked: printf_spec is a 64-bit bitfield struct
  # that format_decode builds with byte/halfword stores and number() reads
  # whole). Wide loads over several in-flight NARROW stores: the forward must
  # merge every younger-than-nothing/older-than-the-load byte, in age order.
  li   t0, 0x1122334455667788
  sd   t0, 0(sp)
  fence rw, rw
  # eight byte stores, then the doubleword load (all eight forwarded)
  li   t1, 0xA0
  sb   t1, 0(sp)
  li   t1, 0xA1
  sb   t1, 1(sp)
  li   t1, 0xA2
  sb   t1, 2(sp)
  li   t1, 0xA3
  sb   t1, 3(sp)
  li   t1, 0xA4
  sb   t1, 4(sp)
  li   t1, 0xA5
  sb   t1, 5(sp)
  li   t1, 0xA6
  sb   t1, 6(sp)
  li   t1, 0xA7
  sb   t1, 7(sp)
  ld   t2, 0(sp)
  li   t3, 0xA7A6A5A4A3A2A1A0
#ifdef MEM_ORDER_NEGATIVE
  xori t3, t3, 1
#endif
  bne  t2, t3, fail_t2
  # a halfword and a word over the previous bytes, then the doubleword and
  # each narrow store read back on its own
  li   t1, 0xB1B0
  sh   t1, 2(sp)
  li   t1, 0xC3C2C1C0
  sw   t1, 4(sp)
  ld   t2, 0(sp)
  li   t3, 0xC3C2C1C0B1B0A1A0
  bne  t2, t3, fail_t2
  lhu  t2, 2(sp)                 # the halfword store alone
  li   t3, 0xB1B0
  bne  t2, t3, fail_t2
  lwu  t2, 4(sp)                 # the word store alone
  li   t3, 0xC3C2C1C0
  bne  t2, t3, fail_t2
  # older wide store still in flight (late data) under younger narrow stores
  li   t1, 0x7fffffffffffffff
  li   t4, 3
  divu t5, t1, t4
  andi t5, t5, 0
  li   t1, 0xDDDDDDDDDDDDDDDD
  add  t1, t1, t5
  sd   t1, 8(sp)                 # older, data late
  li   t1, 0xEE
  sb   t1, 9(sp)                 # younger byte inside it
  li   t1, 0xFFFF
  sh   t1, 14(sp)                # younger halfword inside it
  ld   t2, 8(sp)
  li   t3, 0xFFFFDDDDDDDDEEDD
  bne  t2, t3, fail_t2
  lhu  t2, 8(sp)
  li   t3, 0xEEDD
  bne  t2, t3, fail_t2

#elif STAGE == 48
  # T32: store-to-load forwarding THROUGH TRANSLATION with VA != PA (Linux:
  # kernel VAs 0xffffffff8..., physical 0x8...). Data accesses go through
  # satp with MPRV (MPP=S) at a high Sv39 alias of the stack
  # (0xffffffffc0000000 -> 0x80000000). Shape of the boot deadlock
  # (sched_clock_noinstr): the HEAD load's address arrives late (divu chain);
  # a younger store to a stack slot and a still-younger load of the same slot
  # issue first. That load must forward from the speculative store (VA key vs
  # PA key); if it instead parks in WAIT_PAGE_OFFSET until the store drains,
  # the store cannot commit behind the unretired head load and the LU is held
  # -- the run times out. Spike: trivially correct.
  csrr s1, mtvec
  la   t0, .Lvm3_handler
  csrw mtvec, t0
  la   t1, .Lvm3_pt
  li   t2, (0x80000 << 10) | 0xCF
  sd   t2, 16(t1)                      # VPN2 = 2 (identity)
  li   t3, 2048
  add  t3, t3, t1
  sd   t2, 2040(t3)                    # VPN2 = 0x1ff (high alias)
  srli t1, t1, 12
  li   t2, 8
  slli t2, t2, 60
  or   t1, t1, t2
  csrw satp, t1
  sfence.vma
  li   t0, -1
  srli t0, t0, 10
  csrw pmpaddr0, t0
  li   t0, 0x0F
  csrw pmpcfg0, t0
  # the alias of this frame
  li   t5, 0x80000000
  sub  a0, sp, t5
  li   t5, 0xffffffffc0000000
  add  a0, a0, t5                      # a0 = alias(sp)
  li   t0, 0x5a5a5a5a5a5a5a5a
  sd   t0, 0(sp)                       # the head load's slot, physical write
  sd   zero, 40(sp)
  fence rw, rw
  li   t0, (1 << 17) | (1 << 11)       # MPRV | MPP = S: data translated
  csrs mstatus, t0
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0                       # 0, late
  add  t4, a0, t3                      # head load address, late
  ld   t5, 0(t4)                       # HEAD load (through the alias)
  li   t6, 0x1234567890abcdef
  sd   t6, 40(a0)                      # younger store through the alias (speculative behind the head)
  ld   a1, 40(a0)                      # youngest: must forward from the store above
  li   t0, (1 << 17) | (3 << 11)
  csrc mstatus, t0                     # MPRV off
  csrw satp, zero
  sfence.vma
  li   t0, 0x5a5a5a5a5a5a5a5a
#ifdef MEM_ORDER_NEGATIVE
  xori t0, t0, 1
#endif
  bne  t5, t0, fail_t2
  bne  a1, t6, fail_t2
  csrw mtvec, s1
  j    .Lvm3_done
  .balign 4
.Lvm3_handler:
  j    fail_trap_cause                 # no trap is expected
  .section .data
  .balign 4096
.Lvm3_pt:
  .space 4096
  .text
.Lvm3_done:

#elif STAGE == 49
  # T33: stage 48 with PARTIAL coverage -- the younger store writes only the
  # low word of the slot the youngest load reads as a doubleword. Forwarding
  # cannot complete the load, so it parks in WAIT_PAGE_OFFSET on a store that
  # is speculative behind the late-address head load; without the load-unit
  # replay the unit is held and the core deadlocks. Bare mode (VA == PA) is
  # enough to show it. Spike: trivially correct.
  li   t0, 0x5a5a5a5a5a5a5a5a
  sd   t0, 0(sp)
  li   t0, 0x1111111122222222
  sd   t0, 40(sp)
  fence rw, rw
  li   t1, 0x7fffffffffffffff
  li   t2, 3
  divu t3, t1, t2
  andi t3, t3, 0                       # 0, late
  add  t4, sp, t3                      # head load address, late
  ld   t5, 0(t4)                       # HEAD load
  li   t6, 0x33333333
  sw   t6, 40(sp)                      # younger store, low word only (speculative behind the head)
  ld   a1, 40(sp)                      # youngest: partially covered -> cannot forward
  li   t0, 0x5a5a5a5a5a5a5a5a
#ifdef MEM_ORDER_NEGATIVE
  xori t0, t0, 1
#endif
  bne  t5, t0, fail_t2
  li   t0, 0x1111111133333333
  bne  a1, t0, fail_t2

#elif STAGE == 50
  # T34 hunt: WT dcache ACK-before-check stress. 64 doubleword stores to a
  # 512-byte region (8 lines), each interleaved with loads from another
  # region so the wbuffer's tag-check port is contended and the write-through
  # ACK can return before the check; then every word is read back through the
  # cache (no fence). A lost or half-applied fixup shows as a wrong word.
  la   s2, .Lt34_region
  la   s3, .Lt34_other
  li   s4, 0
  li   s5, 64
.Lt34_loop:
  slli t0, s4, 3
  add  t1, s2, t0                  # &region[i]
  li   t2, 0x0101010101010101
  mul  t3, t2, s4                  # value i*0x0101.. (distinct, both halves nonzero for i>0)
  addi t3, t3, 0x5a5
  sd   t3, 0(t1)
  andi t4, s4, 0x3f
  slli t4, t4, 3
  add  t5, s3, t4
  ld   t6, 0(t5)                   # contention loads
  ld   t6, 64(t5)
  ld   t6, 128(t5)
  addi s4, s4, 1
  bne  s4, s5, .Lt34_loop
  # read back
  li   s4, 0
.Lt34_chk:
  slli t0, s4, 3
  add  t1, s2, t0
  ld   t3, 0(t1)
  li   t2, 0x0101010101010101
  mul  t4, t2, s4
  addi t4, t4, 0x5a5
#ifdef MEM_ORDER_NEGATIVE
  xori t4, t4, 1
#endif
  bne  t3, t4, fail_t2
  addi s4, s4, 1
  bne  s4, s5, .Lt34_chk
  j    .Lt34_done
  .section .data
  .balign 64
.Lt34_region:
  .space 512
  .balign 64
.Lt34_other:
  .space 1024
  .text
.Lt34_done:

#elif STAGE == 51
  # T34: WT wbuffer tag-check pointer reuse. A write-through ACK can free a
  # wbuffer slot and a new store re-allocate it while the slot's tag check
  # (two cycles) is still in flight; the result (checked/hit_oh of the OLD
  # word's line) must not land on the new occupant. Sweep: pairs of stores to
  # two distinct cached lines with 0..7 cycles between them, both lines warm
  # in the cache, then read both back through the cache (no fence); 256 pairs.
  la   s2, .Lt34b_a
  la   s3, .Lt34b_b
  # warm both regions (16 lines each) into the L1
  li   t0, 0
.Lt34b_warm:
  slli t1, t0, 6
  add  t2, s2, t1
  ld   zero, 0(t2)
  add  t2, s3, t1
  ld   zero, 0(t2)
  addi t0, t0, 1
  li   t1, 16
  bne  t0, t1, .Lt34b_warm
  li   s4, 0
  li   s5, 256
.Lt34b_loop:
  andi t0, s4, 0xf
  slli t1, t0, 6                   # line k
  add  t2, s2, t1
  add  t3, s3, t1
  andi t4, s4, 0x38                # 8-byte word within the line: (k>>3)&7
  add  t2, t2, t4
  add  t3, t3, t4
  addi t5, s4, 0x100               # value A = 0x100+k
  slli t6, s4, 8
  addi t6, t6, 0x55                # value B = k<<8 | 0x55
  sd   t5, 0(t2)                   # store A
  andi a0, s4, 7                   # 0..7 filler ops between the stores
  beqz a0, .Lt34b_sb
.Lt34b_fill:
  addi a1, a1, 1
  addi a0, a0, -1
  bnez a0, .Lt34b_fill
.Lt34b_sb:
  sd   t6, 0(t3)                   # store B (re-uses the freed slot if the ACK was fast)
  ld   a2, 0(t3)
  ld   a3, 0(t2)
#ifdef MEM_ORDER_NEGATIVE
  xori t6, t6, 1
#endif
  bne  a2, t6, fail_t2
  bne  a3, t5, fail_t2
  addi s4, s4, 1
  bne  s4, s5, .Lt34b_loop
  j    .Lt34b_done
  .section .data
  .balign 64
.Lt34b_a:
  .space 1024
  .balign 64
.Lt34b_b:
  .space 1024
  .text
.Lt34b_done:

#elif STAGE == 52
  # T36: the MMU's canonical-address check must apply to the request whose
  # DTLB result is being examined, not to the next one in the pipe. Data
  # translation on (MPRV, MPP=S, Sv39 identity gigapage); each unrolled copy
  # issues a store to a warm, writable page, then a late-resolving taken
  # branch (cold, predicted not-taken) whose wrong path loads from a
  # NON-CANONICAL pointer (the jent_memaccess shape: 0x0000053100000000).
  # Pre-fix the wrong-path load's canonical check, one cycle behind the
  # store's translation, became a STORE_PAGE_FAULT on the store. Spike: no
  # trap at all.
  csrr s1, mtvec
  la   t0, .Lnc_handler
  csrw mtvec, t0
  la   t1, .Lnc_pt
  li   t2, (0x80000 << 10) | 0xCF
  sd   t2, 16(t1)                      # VPN2 = 2: identity gigapage, RWX AD
  srli t1, t1, 12
  li   t2, 8
  slli t2, t2, 60
  or   t1, t1, t2
  csrw satp, t1
  sfence.vma
  li   t0, -1
  srli t0, t0, 10
  csrw pmpaddr0, t0
  li   t0, 0x0F
  csrw pmpcfg0, t0
  li   t0, (1 << 17) | (1 << 11)       # MPRV | MPP = S: data translated
  csrs mstatus, t0
  ld   zero, -24(sp)                   # warm the DTLB for the stack page
  li   s4, 0x0000053100000000          # non-canonical (bit 40 set, bit 38 clear)
  li   s5, 0x7fffffffffffffff
  li   s6, 3
  .rept 24
  divu t3, s5, s6                      # late, nonzero
  sd   s4, -24(sp)                     # the store: valid, writable, DTLB hit
  bnez t3, 1f                          # taken; cold -> predicted not-taken
  ld   t0, 0(s4)                       # wrong path: non-canonical load right behind the store
  ld   t0, 8(s4)
1:
  .endr
  li   t0, (1 << 17) | (3 << 11)
  csrc mstatus, t0                     # MPRV off
  csrw satp, zero
  sfence.vma
  ld   t0, -24(sp)
#ifdef MEM_ORDER_NEGATIVE
  xori t0, t0, 1
#endif
  bne  t0, s4, fail_t2
  csrw mtvec, s1
  j    .Lnc_done
  .balign 4
.Lnc_handler:
  j    fail_trap_cause                 # no trap is expected
  .section .data
  .balign 4096
.Lnc_pt:
  .space 4096
  .text
.Lnc_done:

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
