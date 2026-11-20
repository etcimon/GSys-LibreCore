# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Za64rs reservation-independence discriminator (RFIX backlog: RVZa64rs is
# held at 0 pending exactly this proof). The live exclusive monitor
# (g6lc_axi_lrsc / axi_res_tbl) keys reservations on the exact AXI address —
# a 1-address set, the most conservative legal Za64rs set. Advertising
# RVZa64rs is only honest if a peer store to a NEARBY but different address
# does not spuriously kill the reservation (over-invalidation), while a peer
# store to the SAME address still does (the monitor is not dead).
#
# Two cores are required: the core-local LR->SC issue barrier
# (issue_read_operands.sv lr_sc_pair_q) blocks every plain STORE on the LR's
# own core until the SC issues, so a same-core peer cannot place a store
# between LR and SC. Hart 0 (core 0) runs LR/SC; hart 2 (core 1) is the
# interfering writer on an independent barrier. Sibling/other harts park.
#
#   Phase 1 (independence): hart0 lr.d A ; hart2 sd B ; hart0 sc.d A.
#     A and B share one 64-byte naturally-aligned window (and one 16-byte
#     D$ cache line) but differ in address. Exact-address keying => the B
#     store must NOT invalidate A's reservation => sc.d returns 0 (success).
#   Phase 2 (control):    hart0 lr.d A ; hart2 sd A ; hart0 sc.d A.
#     The same-address store MUST invalidate => sc.d returns nonzero (fail)
#     and A keeps the peer's value. Without this arm a phase-1 pass could
#     mean "reservations never invalidate at all", not "address-exact".
#
# Handshake (all flags on their own lines, >=256 B apart):
#   READY  hart0 -> hart2 : nonzero once A/B/GO/DONE are initialized.
#   GO     hart0 -> hart2 : phase number to service (1 then 2).
#   DONE   hart2 -> hart0 : phase number completed (store committed).
#
# tohost raw codes: 1 pass; 5 = phase1 SC failed (over-invalidation, the
# za64rs defect) or its memory check wrong; 6 = phase2 SC succeeded
# (under-invalidation: monitor not killing same-address reservations);
# 7 = phase2 memory check wrong; 9 = sync timeout; 15 = unexpected trap;
# 32+((mcause<<1)|1) on a trap.
#
# Needs NrCores >= 2 (active harts 0 and 2). Requires +debug_disable and
# +tohost_addr.

  .equ SHARED,  0x80090000     # A = +0, B = +8 (same 16B line, same 64B win)
  .equ A,       SHARED
  .equ B,       SHARED + 8
  .equ GO,      0x80090100
  .equ DONE,    0x80090200
  .equ READY,   0x80090300
  .equ SPIN_TO, 4000000

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap_vec
  csrw mtvec, t1
  andi t1, t0, 1
  bnez t1, park                 # odd harts are SMT siblings: park
  srli s0, t0, 1                # s0 = core index
  beqz s0, hart0                # core 0 -> reservation owner
  li   t2, 1
  beq  s0, t2, hart2            # core 1 -> interfering writer
  j    park

# ---------------------------------------------------------------------------
# hart 0 (core 0): LR/SC owner + reporter
hart0:
  li   s1, A
  li   s2, B
  li   s3, GO
  li   s4, DONE
  li   s5, READY
  li   t0, 0x1111111111111111
  sd   t0, 0(s1)                # A initial
  sd   t0, 0(s2)                # B initial (same value, distinct address)
  sd   zero, 0(s3)              # GO   = 0
  sd   zero, 0(s4)              # DONE = 0
  li   t0, 1
  sd   t0, 0(s5)                # READY = 1  (releases hart2's poll loop)
  fence rw, rw

  # ---- phase 1: independent address B must NOT kill reservation on A ----
  mv   a0, s1                   # rs1 = A
  lr.d t5, (a0)                 # reservation on A
  li   t0, 1
  sd   t0, 0(s3)                # GO = 1  (store; issues once LR retired)
  fence rw, rw
  li   t6, 0                    # spin budget
p1poll:
  ld   t1, 0(s4)                # poll DONE (loads: not barrier-blocked)
  li   t2, 1
  beq  t1, t2, p1go
  addi t6, t6, 1
  li   t2, SPIN_TO
  bltu t6, t2, p1poll
  li   a0, 9                    # sync timeout
  j    report
p1go:
  li   a2, 0x2222222222222222   # new value for A
  sc.d t3, a2, (a0)             # SC on A: expect success (rd==0)
  bnez t3, fail_p1              # nonzero => reservation killed => defect
  ld   t4, 0(s1)
  li   t2, 0x2222222222222222
  bne  t4, t2, fail_p1          # A must hold the SC's new value

  # ---- phase 2: same-address store MUST kill reservation on A (control) --
  li   t0, 0x3333333333333333
  sd   t0, 0(s1)                # reset A (plain store; barrier now clear)
  fence rw, rw
  mv   a0, s1
  lr.d t5, (a0)                 # fresh reservation on A
  li   t0, 2
  sd   t0, 0(s3)                # GO = 2
  fence rw, rw
  li   t6, 0
p2poll:
  ld   t1, 0(s4)
  li   t2, 2
  beq  t1, t2, p2go
  addi t6, t6, 1
  li   t2, SPIN_TO
  bltu t6, t2, p2poll
  li   a0, 9
  j    report
p2go:
  li   a2, 0x4444444444444444
  sc.d t3, a2, (a0)             # SC on A: expect FAIL (rd!=0)
  beqz t3, fail_p2              # zero => reservation survived same-addr store
  ld   t4, 0(s1)
  li   t2, 0x6666666666666666   # A keeps the PEER's value (SC did not write)
  bne  t4, t2, fail_p2

  li   a0, 1
  j    report

fail_p1:      li   a0, 5
             j    report
fail_p2:      li   a0, 6
             j    report

# ---------------------------------------------------------------------------
# hart 2 (core 1): interfering writer
hart2:
  li   s1, GO
  li   s2, DONE
  li   s3, A
  li   s4, B
  li   s5, READY
  # wait for hart0 to finish initializing (READY != 0)
rwait:
  ld   t0, 0(s5)
  beqz t0, rwait
  li   t6, 0                     # last serviced phase
rloop:
  ld   t0, 0(s1)                 # poll GO (loads only)
  beq  t0, t6, rloop             # same phase: keep waiting
  bltu t0, t6, rloop             # stale/garbage: ignore
  # service phase t0: 1 -> store B ; 2 -> store A
  li   t1, 1
  beq  t0, t1, do_b
  li   t2, 0x6666666666666666
  sd   t2, 0(s3)                 # phase2: store A (same address -> must kill)
  fence rw, rw
  j    done_store
do_b:
  li   t2, 0x5555555555555555
  sd   t2, 0(s4)                 # phase1: store B (diff addr, same set)
  fence rw, rw
done_store:
  sd   t0, 0(s2)                 # DONE = phase (store committed + fenced)
  mv   t6, t0
  j    rloop

park:
  wfi
  j    park

report:
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
8: j    8b

trap_vec:
  csrr a0, mcause
  andi a0, a0, 0xff
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 32
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
9: j    9b

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
