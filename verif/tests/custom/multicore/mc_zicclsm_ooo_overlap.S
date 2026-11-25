// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Directed OoO regression for g6lc_zicclsm (OpenWrt printc c=14505435 wedge):
//   An older aligned load in load_unit's ldbuf completes while a younger
//   misaligned (word-wrapping) load or store is active in g6lc_zicclsm
//   (B0_ACTIVE/B0_WAIT/B1_ACTIVE/B1_WAIT or hold_v_q). Without TID-matched
//   passthrough, g6lc_zicclsm swallows the older load's ld_valid_fu_i, leaving
//   its scoreboard/LSQ entry permanently incomplete -> commit deadlock (exit 126).
//
// Tests two overlap patterns on hart0 (other harts park in wfi):
//   1. Cold-line aligned LD (slow D$ miss -> sits in ldbuf) followed directly
//      by a wrapping LD @+7 (hits in D$ -> enters B0_ACTIVE/B0_WAIT/B1_WAIT
//      and hold_v_q while the older miss returns) + dependent SD.
//   2. Cold-line aligned LD followed by a data-dependent branch whose wrong
//      path issues a wrapping LD to a non-idempotent address (0x00ff, exact
//      printc/emit_empty c=14505432-14505435 pattern: stalls in B0_ACTIVE
//      WAIT_SPEC_LOAD while the older aligned LD completes).
//   3. Cold-line aligned LD followed by a wrapping SD @+5 (load completes
//      during store split).
//
// tohost: 1 pass, 0x100+n data mismatch.

  .section .data
  .align 6
  .globl hot_line
hot_line:
  .dword 0x0706050403020100
  .dword 0x0f0e0d0c0b0a0908
  .dword 0x1716151413121110
  .dword 0x1f1e1d1c1b1a1918
  .align 6
  .globl st_buf
st_buf:
  .space 128
  .align 6
  .globl cold_buf
cold_buf:
  // 256 cache lines (16 KiB) -> fresh lines guarantee D$ misses so older
  // aligned loads stay in ldbuf while younger misaligned ops enter zicclsm.
  .space 16384

  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap
  csrw mtvec, t1
  bnez t0, park

  // Initialize cold_buf[i*64] = 0xCAFE0000 + i for i = 0..255
  la   s0, cold_buf
  li   t0, 0
  li   t1, 256
  li   t2, 0xCAFE0000
init_cold:
  add  t3, t2, t0
  sd   t3, 0(s0)
  addi s0, s0, 64
  addi t0, t0, 1
  blt  t0, t1, init_cold
  fence rw, rw

  // Prime hot_line in L1 D$
  la   s1, hot_line
  ld   t0, 0(s1)
  ld   t1, 8(s1)

  // =========================================================================
  // Phase 1: Aligned cold-line load overlapped with wrapping LD @+5 / @+7
  // =========================================================================
  la   s0, cold_buf
  la   s3, st_buf
  li   s4, 0
  li   s5, 128
  li   s6, 0xCAFE0000
  li   s7, 0x0c0b0a0908070605   // expected LD @hot_line+5
p1_loop:
  ld   a2, 0(s0)                // older aligned LD (D$ miss -> stays in ldbuf)
  ld   a3, 5(s1)                // younger wrapping LD (enters zicclsm B0/B1)
  ld   a4, 7(s1)                // back-to-back wrapping LD (also tests hold_v_q)
  sd   a2, 0(s3)                // dependent on a2 (deadlocks if a2 swallowed)
  add  t4, s6, s4
  bne  a2, t4, fail1
  bne  a3, s7, fail2
  addi s0, s0, 64
  addi s4, s4, 1
  blt  s4, s5, p1_loop

  // =========================================================================
  // Phase 2: Exact OpenWrt printc pattern — older aligned LD followed by
  //          alternating mispredicted branch whose wrong path runs a wrapping
  //          LD to non-idempotent address 0x00ff (stalls zicclsm B0_ACTIVE!)
  // =========================================================================
  la   s0, cold_buf
  li   t0, 8192
  add  s0, s0, t0               // lines 128..255 (still cold in L1!)
  li   s4, 128
  li   s5, 256
  li   s8, 0x00ff               // non-idempotent + wrapping offset 7!
p2_loop:
  // Compute branch condition dependent on a slow-ish chain so predictor
  // mispredicts frequently onto wrong_ni_split!
  andi t0, s4, 1
  // Alternate between taken (skip wrong_ni_split) and a second branch
  // Make wrong_ni_split unreachable when t1==0, but train BTB on it via
  // a benign target or alternating direction:
  ld   a2, 0(s0)                // older aligned LD (D$ miss -> in ldbuf!)
  beqz t0, p2_skip              // alternates 0/1 -> mispredicts ~50%!
  // Taken half: safe wrapping load @hot_line+3 (wraps!)
  ld   a3, 3(s1)
  j    p2_join
p2_skip:
  // Guarded with a second branch that is always taken (a0!=0) so
  // wrong_ni_split is purely speculative when mispredicted!
  ld   a4, 1(s1)                // wrapping LD overlapping older a2
  bnez s6, p2_join
wrong_ni_split:
  ld   a5, 0(s8)                // wrapping LD @0x00ff (exact tid=51 trigger!)
  sd   a5, 8(s3)
p2_join:
  sd   a2, 16(s3)               // dependent on a2
  add  t4, s6, s4
  bne  a2, t4, fail3
  addi s0, s0, 64
  addi s4, s4, 1
  blt  s4, s5, p2_loop

  // =========================================================================
  // Phase 3: Older aligned LD overlapped with wrapping SD @st_buf+5
  // =========================================================================
  la   s0, cold_buf
  li   s4, 0
  li   s5, 64
  li   s9, 0x1122334455667788
p3_loop:
  ld   a2, 0(s0)                // older aligned LD
  sd   s9, 5(s3)                // younger wrapping SD (enters zicclsm store split)
  sd   a2, 24(s3)               // dependent on a2
  add  t4, s6, s4
  bne  a2, t4, fail4
  ld   t5, 5(s3)                // verify wrapping SD data
  bne  t5, s9, fail5
  addi s0, s0, 64
  addi s4, s4, 1
  blt  s4, s5, p3_loop

  li   a0, 1
  j    done

fail1: li a0, 0x101; j done
fail2: li a0, 0x102; j done
fail3: li a0, 0x103; j done
fail4: li a0, 0x104; j done
fail5: li a0, 0x105; j done

park:
1:
  wfi
  j    1b

done:
  la   t0, tohost
  sw   a0, 0(t0)
  fence rw, rw
1:
  j    1b

trap:
  csrr a0, mcause
  slli a0, a0, 1
  ori  a0, a0, 1
  addi a0, a0, 0x200
  j    done

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .globl fromhost
fromhost: .dword 0
