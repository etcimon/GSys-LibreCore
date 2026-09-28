// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// End-to-end CBO discriminator for the eWT model (L2CmoEn). A correct machine
// routes cbo.inval through the CMO sideband to the cluster engine, which
// invalidates every L1 copy (including the issuer's) and match-invalidates
// L2/L3, so a later read sees the non-coherent DRAM value. The pre-fix defect
// on WT targets decoded a CBO as a one-byte STORE and the WT write buffer
// never answered data_rvalid, so the store buffer hung forever.
//
// Sequence (hart 0 runs the body; PEER_HART caches the victim line first):
//   h0:    LINE_X <- SEED, read-back; LINE_Y <- VAL_Y; LINE_Z <- filler
//   h0:    release PEER core (CLINT msip), GO=1
//   peer:  spin GO, ld LINE_X (caches SEED in its own L1), RDY=1, spin GO2
//   h0:    spin RDY, then spin mcycle >= POKE_CYCLE — the harness plusarg
//          +mem_poke=<LINE_X>:<POKED>:<cycle> has now written DRAM directly,
//          behind every cache level
//   h0:    cbo.inval LINE_X; ld LINE_X must be POKED (L1+L2 copy gone)
//   h0:    GO2=1; peer re-reads LINE_X, sets OK if it sees POKED — proves the
//          broadcast reached a different core's L1
//   h0:    cbo.clean + cbo.flush LINE_X complete; LINE_X still POKED
//   h0:    cbo.zero LINE_Z works; LINE_Y untouched (the one-byte CBO store
//          mutation would be visible as stray corruption)
//
// Exit code (the harness's tohost banner, = written value >> 1):
// 0 pass, 1 ORACLE_NEGATIVE, 4 poke did not land, 5 h0 read-back
// wrong, 6 peer timeout, 7 peer stale, 8 data lost after clean/flush,
// 9 LINE_Z not zeroed, 10 LINE_Y corrupted, 11 setup read-back wrong,
// 12 mcycle spin timeout. Trap: 32+(mcause&0xff). The store at `done`
// encodes (code<<1)|1 because the RVFI tracer terminates only on an odd
// tohost write — an even code would run to the time_out bound instead.
//
// CBO encodings (Zicbom/Zicboz, MISC-MEM major 0001111, funct3=010):
//   inval imm12=0, clean imm12=1, flush imm12=2, zero imm12=4.

#ifndef PEER_HART
#define PEER_HART 2
#endif
#ifndef POKE_CYCLE
#define POKE_CYCLE 120000
#endif
#ifndef POKED
#define POKED 0xdeadbeefcafef00d
#endif

  .equ LINE_X,   0x80104000
  .equ LINE_Y,   0x80104040
  .equ LINE_Z,   0x80104080
  .equ FLAG_GO,  0x80104100
  .equ FLAG_RDY, 0x80104140
  .equ FLAG_GO2, 0x80104180
  .equ FLAG_OK,  0x801041c0
  .equ FLAG_BAD, 0x80104200
  .equ SEED,     0x5eedc0de11223344
  .equ VAL_Y,    0xa5a5a5a55a5a5a5a
  .equ CLINT_MSIP, 0x02000000
  .equ SPIN_TO,  50000

.macro CBO_INVAL rs
  .4byte (0 << 20) | (\rs << 15) | (2 << 12) | 0x0f
.endm
.macro CBO_CLEAN rs
  .4byte (1 << 20) | (\rs << 15) | (2 << 12) | 0x0f
.endm
.macro CBO_FLUSH rs
  .4byte (2 << 20) | (\rs << 15) | (2 << 12) | 0x0f
.endm
.macro CBO_ZERO rs
  .4byte (4 << 20) | (\rs << 15) | (2 << 12) | 0x0f
.endm

  .option norvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  la   t1, trap
  csrw mtvec, t1
  li   t1, PEER_HART
  beq  t0, t1, peer
  bnez t0, park

  // ---- hart 0: setup ----
  li   s1, LINE_X
  li   s2, LINE_Y
  li   s3, LINE_Z
  li   s4, FLAG_GO
  li   s5, FLAG_RDY
  li   s6, FLAG_GO2
  li   s7, FLAG_OK
  li   s8, FLAG_BAD

  sd   zero, 0(s4)
  sd   zero, 0(s5)
  sd   zero, 0(s6)
  sd   zero, 0(s7)
  sd   zero, 0(s8)
  fence rw, rw

  li   t1, SEED
  sd   t1, 0(s1)                // LINE_X = SEED (write-through to DRAM)
  li   t1, VAL_Y
  sd   t1, 0(s2)                // LINE_Y control
  li   t1, SEED
  sd   t1, 0(s3)                // LINE_Z filler for cbo.zero
  fence rw, rw
  ld   t0, 0(s1)                // read-back installs LINE_X in L1 and L2
  li   t1, SEED
  bne  t0, t1, fail_setup

  // release the peer's core, then ask it to cache LINE_X
  li   t1, 1
  sd   t1, 0(s4)                // GO before msip: order does not matter here
  fence rw, rw
  li   t0, CLINT_MSIP
  sw   t1, (4 * PEER_HART)(t0)

  li   t2, SPIN_TO
1:
  ld   t1, 0(s5)                // wait RDY: peer has LINE_X cached as SEED
  bnez t1, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    fail_peer_to

  // ---- wait until the harness poke has landed behind the caches ----
2:
  li   t3, POKE_CYCLE
  li   t2, SPIN_TO
3:
  csrr t0, mcycle
  bgeu t0, t3, 4f
  addi t2, t2, -1
  bnez t2, 3b
  j    fail_poke_to
4:

  // ---- the CMO under test ----
  fence rw, rw
  mv   a0, s1
  CBO_INVAL 10                  // cbo.inval (a0): every level, every core
  fence rw, rw

  ld   t0, 0(s1)                // must observe the poked DRAM value
  li   t1, POKED
#ifdef ORACLE_NEGATIVE
  xori t1, t1, 1                // arm: demand the wrong value -> check fails
#endif
  bne  t0, t1, fail_stale_h0

  li   t1, 1
  sd   t1, 0(s6)                // GO2: peer re-reads LINE_X
  fence rw, rw

  li   t2, SPIN_TO
5:
  ld   t1, 0(s7)
  bnez t1, 6f
  ld   t1, 0(s8)
  bnez t1, fail_stale_peer
  addi t2, t2, -1
  bnez t2, 5b
  j    fail_peer_to

  // ---- clean and flush must complete and leave data intact ----
6:
  fence rw, rw
  CBO_CLEAN 10                  // cbo.clean (a0)
  CBO_FLUSH 10                  // cbo.flush (a0)
  fence rw, rw
  ld   t0, 0(s1)
  li   t1, POKED
  bne  t0, t1, fail_clean

  // ---- cbo.zero still works ----
  mv   a0, s3
  CBO_ZERO 10                   // cbo.zero (a0)
  fence rw, rw
  ld   t0, 0(s3)
  bnez t0, fail_zero
  ld   t0, 56(s3)
  bnez t0, fail_zero

  // ---- the unaffected line must keep its value ----
  ld   t0, 0(s2)
  li   t1, VAL_Y
  bne  t0, t1, fail_y

  li   a0, 0
  j    done

  // ---- peer hart: caches LINE_X as SEED, re-reads after the CMO ----
peer:
  li   s1, LINE_X
  li   s4, FLAG_GO
  li   s5, FLAG_RDY
  li   s6, FLAG_GO2
  li   s7, FLAG_OK
  li   s8, FLAG_BAD

  li   t2, SPIN_TO
1:
  ld   t1, 0(s4)
  bnez t1, 2f
  addi t2, t2, -1
  bnez t2, 1b
  j    park
2:
  ld   t0, 0(s1)                // genuine miss: peer installs LINE_X = SEED
  fence rw, rw
  li   t1, 1
  sd   t1, 0(s5)                // RDY
  fence rw, rw

  li   t2, SPIN_TO
3:
  ld   t1, 0(s6)
  bnez t1, 4f
  addi t2, t2, -1
  bnez t2, 3b
  j    park
4:
  fence rw, rw
  ld   t0, 0(s1)                // stale L1 copy fails without the broadcast
  li   t1, POKED
  li   t2, FLAG_OK
  li   t3, FLAG_BAD
  beq  t0, t1, 5f
  li   t1, 1
  sd   t1, 0(t3)                // BAD
  j    6f
5:
  li   t1, 1
  sd   t1, 0(t2)                // OK
6:
  fence rw, rw
  j    park

park:
1:
  wfi
  j    1b

fail_setup:
  li   a0, 11
  j    done
fail_poke_to:
  li   a0, 4
  j    done
fail_stale_h0:
#ifdef ORACLE_NEGATIVE
  li   a0, 1                    // armed control: program exit 1, not pass
#else
  li   a0, 5
#endif
  j    done
fail_peer_to:
  li   a0, 6
  j    done
fail_stale_peer:
  li   a0, 7
  j    done
fail_clean:
  li   a0, 8
  j    done
fail_zero:
  li   a0, 9
  j    done
fail_y:
  li   a0, 10
  j    done

done:
  la   t0, tohost
  slli a0, a0, 1
  ori  a0, a0, 1
  sw   a0, 0(t0)
  fence rw, rw
1:
  wfi
  j    1b

trap:
  csrr a0, mcause
  andi a0, a0, 0xff
  addi a0, a0, 32
  j    done

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .globl fromhost
fromhost: .dword 0
