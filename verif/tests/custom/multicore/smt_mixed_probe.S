# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# T6b-3 exit / T6b-4a measurement probe — two-hart mixed-residency soak.
#
#   hart 1 (checksum hart): switches to S-mode on its own Sv39 root (data VA
#     window 0x4000_0000 -> its private PA page), runs four deterministic
#     integer kernels over that window, folds the results into a 64-bit
#     checksum, programs its own PMU (mhpmcounter3 = retired), reports
#     RES[1], then spins writing value-1 stores to the shared ping-pong words
#     behind LFSR-mispredicted branches (the stores almost always squash, so
#     the shared words architecturally only ever contain 0s).
#   hart 0 (storm hart): M-mode bare. (a) LFSR mispredict storm, (b) store->
#     load pointer-chase replay storm over its private region, (c) shared-page
#     ping-pong: store 0 to SHARED[i], load it back, count non-zero reads —
#     a speculative peer store forwarded across harts is the ONLY way to read
#     1 (hart 1's shared-word stores are squashed, never committed), (d) CLINT
#     timer interrupt accounting. Waits RES[1], writes tohost.
#
# Builds:
#   (none)             full two-hart probe
#   -DSOLO             hart 0 parks in WFI; hart 1 runs alone and exits.
#                      Solo-vs-mixed is a *runtime* branch on probe_solo
#                      (.data), so .text is byte-identical between the two
#                      builds and the hart-1 (pc, rd, value) commit streams
#                      are literally comparable.
#   -DEXPECT_CSUM=...  hart 1 compares its checksum (see provenance below)
#
# Checksum reference: EXPECT_CSUM=3287142068561700632 (0x2d9e464b9adce718).
#   Recorded by the +solo run on the mixed-residency model
#   (t6b4-solo-mixed-v1, work-ver-t6b4-mixed-v1) and independently reproduced
#   by the protected in-order anchor model (t6b4-probe-anchor-v1) — i.e. the
#   value is reference-model-checked, not self-referential.
#
# Build: verif/tests/custom/multicore/smt_mixed_probe_build.sh (all three
# flavours share .text — the solo/mixed split is a runtime branch on
# probe_solo in .data).
#
# tohost: 1 = pass, else fail code.

  .option norvc
  .section .text.init
  .globl _start
_start:
  la    t0, m_trap
  csrw  mtvec, t0
  # norelax is required: without it the linker relaxes this very `la` to
  # `mv gp,gp`, leaving gp at its reset value — and every later gp-relative
  # reference (e.g. `la sp,_stk_base` once it drifts within gp range) is
  # silently corrupt.
  .option push
  .option norelax
  la    gp, __global_pointer$
  .option pop
  csrr  t0, mhartid
  # per-hart M stack: stk_base + (hart+1)*64KiB
  la    sp, _stk_base
  addi  t1, t0, 1
  slli  t1, t1, 16
  add   sp, sp, t1
  bnez  t0, hart1

  # Solo-vs-mixed is decided inside storm_main on probe_solo (.data) so the
  # .text of the two build flavours is identical.
  call  storm_main
0:  j     0b

hart1:
  call  hart1_main
0:  j     0b

# ---------------------------------------------------------------------------
# spec_pad8(a0 = dst, a1 = value, a2 = divisor (must be 1)):
# speculatively store a1 to a0[0..7]. The stores sit on a path only reachable
# through a *wrong RAS prediction*: the `call` pushes the spec block's
# address on the return-address stack; the inner `ret` predicts that address
# but its architectural target (ra = 2f) is the block's end, so the stores
# are fetched, dispatched into the speculative store queue, and squashed on
# resolve — they can NEVER commit, on any model (in-order resolves the jalr
# before the younger stores issue). A cross-hart read of those words can
# therefore only observe them through peer-speculative forwarding (the
# STB/LSQ_NO_HART mutations).
#
# The resolve is deliberately delayed: ra comes from TWO serial 64-bit
# divides (ra = (2f / a2) / a2 = 2f), so the jalr cannot resolve for
# ~70-120 cycles — long enough for the predicted stream's stores to be
# fetched, dispatched and issued into the speculative store queue before
# the squash lands. A plain `la ra,2f` resolved the ret in ~10 cycles (the
# wrong-path stores never reached the queue) and a single divide left a
# ~15-25 cycle residency that the peer's loads consistently missed by
# ~50 cycles — both leaving the STB/LSQ_NO_HART seams unstimulated.
  .align 2
  .globl spec_pad8
spec_pad8:
  addi  sp, sp, -16
  sd    ra, 8(sp)
  call  1f                # RAS push = fall-through (the spec block below)
  # ---- speculative-only path ----
  sd    a1, 0(a0)
  sd    a1, 8(a0)
  sd    a1, 16(a0)
  sd    a1, 24(a0)
  sd    a1, 32(a0)
  sd    a1, 40(a0)
  sd    a1, 48(a0)
  sd    a1, 56(a0)
  j     2f                # real path skips the stores
1:la    t2, 2f            # real return target (not the RAS top)
  div   t3, t2, a2        # a2==1: t3 = 2f after ~35-60 cycles
  div   ra, t3, a2        # ra = 2f after a second serial divide (~70-120cy)
  ret                     # predicts the spec block; resolves to 2f -> squash
2:ld    ra, 8(sp)
  addi  sp, sp, 16
  ret

# ---------------------------------------------------------------------------
# M-mode trap vector (both harts). Saves all caller-saved registers, calls
# m_trap_c(mhartid): returns nonzero to resume (hart-0 timer tick) or 0 to
# park (any other trap is a verdict the handler already published in RES[],
# or already wrote tohost).
  .align 2
m_trap:
  addi  sp, sp, -144
  sd    ra, 0(sp)
  sd    t0, 8(sp)
  sd    t1, 16(sp)
  sd    t2, 24(sp)
  sd    a0, 32(sp)
  sd    a1, 40(sp)
  sd    a2, 48(sp)
  sd    a3, 56(sp)
  sd    a4, 64(sp)
  sd    a5, 72(sp)
  sd    a6, 80(sp)
  sd    a7, 88(sp)
  sd    t3, 96(sp)
  sd    t4, 104(sp)
  sd    t5, 112(sp)
  sd    t6, 120(sp)
  csrr  a0, mhartid
  call  m_trap_c
  beqz  a0, 1f
  ld    ra, 0(sp)
  ld    t0, 8(sp)
  ld    t1, 16(sp)
  ld    t2, 24(sp)
  ld    a0, 32(sp)
  ld    a1, 40(sp)
  ld    a2, 48(sp)
  ld    a3, 56(sp)
  ld    a4, 64(sp)
  ld    a5, 72(sp)
  ld    a6, 80(sp)
  ld    a7, 88(sp)
  ld    t3, 96(sp)
  ld    t4, 104(sp)
  ld    t5, 112(sp)
  ld    t6, 120(sp)
  addi  sp, sp, 144
  mret
1:  wfi
  j     1b

# ---------------------------------------------------------------------------
# Hart-0 S-mode stub for the TLB witness. Entered via mret (no ra, no frame
# of its own): calls h0_s_witness as a real function so its ret is valid,
# then ecalls back to M-mode; the handler's mepc+4 resume lands on the jump
# to storm_main's h0_wit_done continuation label.
  .align 2
  .globl h0_s_stub
h0_s_stub:
  call  h0_s_witness
  ecall
  j     h0_wit_done

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost:   .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0

  .section .data
  .align 3
  # Verdict / handshake state — .data so the harness loads the zeros.
  .globl RES
RES:          .dword 0, 0, 0, 0
  .globl timer_seen
timer_seen:   .dword 0
  .globl tlb_bad
tlb_bad:      .dword 0
  # Mode flags: only the .data initializers differ between build flavours,
  # so .text is byte-identical and commit streams compare literally.
  .globl probe_solo
probe_solo:
#ifdef SOLO
  .dword 1
#else
  .dword 0
#endif
  # 1: hart 0's S-mode witness uses VA 0x4000_0000 — the same VA window hart 1
  #    maps — so the run exercises the TLB hart tag (mixed residency only).
  # 0: hart 0's witness uses VA 0x4020_0000 (L1[1]) — no aliasing; used on the
  #    drained/anchor models where the shared TLB carries no hart tag (the
  #    documented pre-existing drained-TLB-sharing limitation).
  .globl probe_tlb_alias
probe_tlb_alias:
#ifdef NOALIAS
  .dword 0
#else
  .dword 1
#endif
  # Hart 0 -> hart 1 "my phases are done" handshake (replaces RES[1] waits so
  # hart 1 keeps producing decode/queue pressure until hart 0 finishes).
  .globl probe_done
probe_done:   .dword 0
  .globl PRT
PRT:          .zero 128   # probe readout words (architectural PMU etc.)

  # Sv39 roots. Root[1] -> that hart's L1 table (data VA window
  # 0x4000_0000); root[2] -> identity gigapage over
  # 0x8000_0000-0xBFFF_FFFF (code, stacks, RES, SHARED). Each L1[0] is a
  # 2 MiB megapage leaf to the hart's own private page:
  #   hart 0: VA 0x4000_0000 -> PA 0x8420_0000
  #   hart 1: VA 0x4000_0000 -> PA 0x8440_0000
  # Without a TLB hart tag the two mappings alias the same VA.
  .align 12
  .globl pgtbl_h1
pgtbl_h1:
  .dword 0
  .dword 0                                            # [1] filled in C (ptr)
  .dword ((0x80000000 >> 12) << 10) | 0xEF            # identity giga leaf
  .zero  4096 - 24
  .align 12
  .globl pgtbl_h1_l1
pgtbl_h1_l1:
  .dword ((0x84400000 >> 12) << 10) | 0xE7            # mega leaf V|R|W|A|D|G
  .zero  4096 - 8

  # hart 0's root: same shape, L1[0] maps the same VA window to hart 0's
  # private page 0x8420_0000.
  .align 12
  .globl pgtbl_h0
pgtbl_h0:
  .dword 0
  .dword 0                                            # [1] filled in C (ptr)
  .dword ((0x80000000 >> 12) << 10) | 0xEF
  .zero  4096 - 24
  .align 12
  .globl pgtbl_h0_l1
pgtbl_h0_l1:
  .dword ((0x84200000 >> 12) << 10) | 0xE7
  .dword ((0x84200000 >> 12) << 10) | 0xE7  # [1] VA 0x4020_0000 -> PA 0x8420_0000
  .zero  4096 - 16

  .section .bss
  .align 4
_stk_base:
  .zero  3 * 0x10000
