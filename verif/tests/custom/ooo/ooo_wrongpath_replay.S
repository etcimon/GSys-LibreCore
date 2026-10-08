# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# T20 defect A — a wrong-path load's memory-order replay refetches the wrong
# path after the branch that cancelled it already redirected the frontend.
#
# Shape (ooocoh-t19-server-osbi-48M hart 5, `aclint_mtimer_sync+0x16`): a
# cold, always-taken forward `beqz` is predicted not-taken; on its fall-through
# an older store whose ADDRESS resolves late (cold D$ miss) is followed by a
# load to the same word whose address is ready at once.  With MemDepPredEn
# the untrained load bypasses the unresolved store (g6lc_iq may_bypass), the
# store's address then arrives, g6lc_lsq flags a memory-order violation on
# the load and scoreboard.sv sets `cancelled | replay` on it (line ~605).
# When the branch resolves taken the younger-cancel marks the same entries
# cancelled (replay untouched).  At commit the dropped load still carries
# `replay`: commit_stage raises flush_commit + replay_o, the controller sets
# set_pc_commit + mem_replay_pc, and the frontend/PC bank restart at the
# WRONG-PATH load's PC — the instructions after it then retire (boot: the
# `amoswap` that corrupted the heap and the `ld ra` that trapped).
#
# Each pass: ecall/mret (cold predictors), `k` chained `remu` of ~n cycles
# (branch resolve delay), the branch, the wrong path {cold `ld` -> store
# address, `sd` sentinel to probe, `ld` probe (violation candidate), `sd`
# sentinel to probe2 (the replay witness), `addi t2`}, then the taken target.
# Self-check only.  Exit codes (a0 -> tohost = 2*a0+1):
#   0  pass (no wrong-path instruction retired)
#   2  REPLAY LEAK: probe2 carries the sentinel (wrong path refetched after
#      the mispredict, exactly the boot's mechanism)
#   3  probe carries the sentinel (wrong-path store committed)
#   4  wrong-path filler `addi t2` committed without probe2 (other leak)
#   5  taken-path counter wrong
#   9  unexpected trap

#define SENTINEL 0x5e17

  .option push
  .option norvc
  .globl main
main:
  la   s8, probe
  la   s6, probe2
  la   s9, work
  la   s2, coldarea
  li   s11, SENTINEL
  li   s4, 0                    # taken-path counter
  li   s7, 0                    # expected count
  li   t2, 0                    # wrong-path filler witness
  li   s3, 0                    # sticky OR of probe reads
  li   s5, 0                    # sticky OR of probe2 reads
  li   a6, 1

.macro BPFLUSH
#ifndef NO_BPFLUSH
  ecall
#endif
.endm

# k chained remu of ~n divider steps each: t0 = 0 after ~k*n cycles
.macro COND k, n
  slli t4, a6, \n
  .rept \k
  remu t0, t4, a6
  or   t4, t4, t0
  slli t4, t4, 0
  .endr
  remu t0, t4, a6
.endm

.macro PASS id, k, n, pre, tgt
  BPFLUSH
  COND \k, \n
  beqz t0, \tgt\()f             # always taken; cold -> predicted not-taken
  .rept \pre
  addi t2, t2, 1                # wrong path filler
  .endr
  ld   t3, 0(s2)                # wrong path: cold line (D$ miss) -> 0, slow address producer
  add  t3, t3, s8               # = probe
  sd   s11, 0(t3)               # wrong path: store whose address resolves late
  ld   t1, 0(s8)                # wrong path: same word, address ready -> bypasses, then violates
  sd   s11, 0(s6)              # wrong path: replay witness (probe2)
  addi t2, t2, 1                # wrong path filler
\tgt:
  addi s2, s2, 64               # next cold line for the next pass
  addi s4, s4, 1                # taken-path work
  sd   s4, 0(s9)
  ld   t1, 0(s8)
  or   s3, s3, t1
  ld   t1, 0(s6)
  or   s5, s5, t1
  addi s7, s7, 1
.endm

# Sweep: resolve delay k*n from ~16 to ~190 cycles, with and without filler.
  PASS   0, 1, 16, 0, 1
  PASS   1, 1, 24, 0, 1
  PASS   2, 1, 32, 0, 1
  PASS   3, 1, 40, 0, 1
  PASS   4, 1, 48, 0, 1
  PASS   5, 1, 56, 0, 1
  PASS   6, 1, 63, 0, 1
  PASS   7, 2, 40, 0, 1
  PASS   8, 2, 48, 0, 1
  PASS   9, 2, 56, 0, 1
  PASS  10, 2, 63, 0, 1
  PASS  11, 3, 48, 0, 1
  PASS  12, 3, 63, 0, 1
  PASS  13, 1, 16, 2, 1
  PASS  14, 1, 32, 2, 1
  PASS  15, 1, 48, 2, 1
  PASS  16, 1, 63, 2, 1
  PASS  17, 2, 48, 2, 1
  PASS  18, 2, 63, 2, 1
  PASS  19, 3, 63, 2, 1
  PASS  20, 1, 8, 0, 1
  PASS  21, 1, 12, 0, 1
  PASS  22, 1, 20, 0, 1
  PASS  23, 1, 28, 0, 1
  PASS  24, 1, 36, 0, 1
  PASS  25, 1, 44, 0, 1
  PASS  26, 1, 52, 0, 1
  PASS  27, 1, 60, 0, 1
  PASS  28, 2, 20, 0, 1
  PASS  29, 2, 28, 0, 1
  PASS  30, 2, 36, 0, 1
  PASS  31, 3, 36, 0, 1

# Final checks
  ld   t1, 0(s6)
  or   s5, s5, t1
  bnez s5, replay_leak
  ld   t1, 0(s8)
  or   s3, s3, t1
  bnez s3, store_leak
  bnez t2, filler_committed
  bne  s4, s7, count_wrong
  li   a0, 0
  jal  exit

replay_leak:
  li   a0, 2
  jal  exit
store_leak:
  li   a0, 3
  jal  exit
filler_committed:
  li   a0, 4
  jal  exit
count_wrong:
  li   a0, 5
  jal  exit

# ecall -> skip the ecall; any other trap -> exit 9
  .globl handle_trap
handle_trap:
  li   t0, 11
  bne  a0, t0, 1f
  addi a0, a1, 4
  ret
1:
  li   a0, 9
  j    _exit
  .option pop

  .data
  .balign 64
probe:     .dword 0
  .balign 64
probe2:    .dword 0
  .balign 64
work:      .dword 0
  .balign 64
coldarea:  .skip 64*64          # .data (not .bss): must read back as zero
