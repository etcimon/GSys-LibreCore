# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# hyp8 r61: an OLDER plain store whose address arrives late (behind a
# dependent load chain) with a YOUNGER address-ready AMO right behind it.
# Under OoO issue the AMO reaches the amo_buffer first; the store unit
# used to gate every store on store_buffer_ready & amo_buffer_ready, so
# the older store could never post, never commit, and the AMO behind it
# never reached the commit head: a total wedge (r31 Linux stall at the
# kernel's first spinlock after paging). The fixed store unit admits a
# plain store on store_buffer_ready alone.
#
# Each variant performs the pattern with a different chain depth and AMO
# kind, then checks memory. tohost = 1 on success; (2*k+1) names the
# first failing variant; a wedge shows as a budget-out (no tohost).
.option norvc
.section .text.init
.globl _start
_start:
  la    s0, data
  li    s7, 0

# ---------------------------------------------------------------- v1
# chain depth 3 -> sd ; amoadd.w on another word
  li    t2, 0x1111
  ld    a0, 0(s0)          # -> &data+64 (slot A)
  ld    a0, 0(a0)          # -> &data+72 (slot B)
  ld    a0, 0(a0)          # -> &data+80 (slot C): store target
  sd    t2, 0(a0)          # older store, late address
  li    a4, 1
  la    a5, lockw
  amoadd.w a3, a4, (a5)    # younger AMO, address ready at issue
  fence
  ld    t3, 80(s0)
  li    t4, 0x1111
  bne   t3, t4, fail1
  lw    t3, 0(a5)
  li    t4, 1
  bne   t3, t4, fail1
  j     v2
fail1:
  li    s7, 1
  j     report

# ---------------------------------------------------------------- v2
# chain depth 5 -> sw ; amoswap.d
v2:
  li    t2, 0x2222
  ld    a0, 0(s0)
  ld    a0, 0(a0)
  ld    a0, 0(a0)
  ld    a0, 8(a0)          # slot D (&data+88) -> &data+96 (slot E)
  sw    t2, 0(a0)
  li    a4, 0x55
  la    a5, lockd
  amoswap.d a3, a4, (a5)
  fence
  lw    t3, 96(s0)
  li    t4, 0x2222
  bne   t3, t4, fail2
  ld    t3, 0(a5)
  li    t4, 0x55
  bne   t3, t4, fail2
  bne   a3, zero, fail2    # previous value was 0
  j     v3
fail2:
  li    s7, 2
  j     report

# ---------------------------------------------------------------- v3
# two late stores then two AMOs (buffer depth 1 pressure)
v3:
  li    t2, 0x3333
  li    t5, 0x4444
  ld    a0, 0(s0)
  ld    a0, 0(a0)
  ld    a0, 0(a0)          # slot C
  sd    t2, 24(a0)         # -> &data+104
  sd    t5, 32(a0)         # -> &data+112
  li    a4, 2
  la    a5, lockw
  amoadd.w a3, a4, (a5)
  amoadd.w a6, a4, (a5)
  fence
  ld    t3, 104(s0)
  li    t4, 0x3333
  bne   t3, t4, fail3
  ld    t3, 112(s0)
  li    t4, 0x4444
  bne   t3, t4, fail3
  lw    t3, 0(a5)
  li    t4, 5              # 1 + 2 + 2
  bne   t3, t4, fail3
  j     v4
fail3:
  li    s7, 3
  j     report

# ---------------------------------------------------------------- v4
# wrong-path AMO: a loop trains the branch not-taken, the last iteration
# is taken after a slow load, so the fall-through amoadd issues
# speculatively and is cancelled. A dead AMO left in the depth-1
# amo_buffer blocks the correct-path AMO forever (budget-out); lock2 must
# also stay untouched by the wrong path.
v4:
  li    t0, 0
  li    t6, 7
  la    a5, lock2
  li    a4, 1
v4_loop:
  ld    a0, 0(s0)          # dependent chain delays the branch resolve
  ld    a0, 0(a0)
  ld    a0, 0(a0)
  sub   a1, t0, t6         # 0 only on the last iteration
  beqz  a1, v4_taken       # not-taken x7, then taken
  amoadd.w a3, a4, (a5)    # wrong path on the last iteration
  addi  t0, t0, 1
  j     v4_loop
v4_taken:
  la    a6, lock3
  amoadd.w a3, a4, (a6)    # correct-path AMO needs the buffer
  fence
  lw    t3, 0(a5)
  li    t4, 7              # seven committed fall-through amoadds
  bne   t3, t4, fail4
  lw    t3, 0(a6)
  li    t4, 1
  bne   t3, t4, fail4
  j     report
fail4:
  li    s7, 4

# ---------------------------------------------------------------- verdict
report:
  beqz  s7, pass
  slli  t0, s7, 1
  addi  t0, t0, 1
  la    t1, tohost
  sw    t0, 0(t1)
  j     done
pass:
  li    t0, 1
  la    t1, tohost
  sw    t0, 0(t1)
done:
  j     done

.section .data
.align 6
data:
  .dword data+64          # [0]  -> slot A
  .dword 0, 0, 0, 0, 0, 0, 0
  .dword data+72          # [64] slot A -> slot B
  .dword data+80          # [72] slot B -> slot C
  .dword 0                # [80] slot C: v1 store target
  .dword data+96          # [88] slot D -> slot E
  .dword 0                # [96] slot E: v2 store target
  .dword 0                # [104] v3 store 1
  .dword 0                # [112] v3 store 2
  .dword 0                # [120]
.align 6
lockw: .word 0
.align 3
lockd: .dword 0
.align 6
lock2: .word 0
.align 6
lock3: .word 0

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
