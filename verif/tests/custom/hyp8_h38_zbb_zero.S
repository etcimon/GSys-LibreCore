// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// hyp8 H38: directed regression for the g6lc_hyp_lzc WIDTH2 recursive
// base-case wrap -- an empty 2-bit vector recursed into WIDTH=1 leaves
// added 1+1 in a one-bit count and wrapped to zero, so an all-zero CTZ/CLZ
// input reported 63 instead of 64. Word forms are checked as controls.
// Whole-core smoke: raw .word encodings for ctz/clz/ctzw/clzw/orc.b
// (GCC_FLAGS lacks Zbb). tohost: 1 pass, 0x101.. failing section.

  .macro FAIL n
    li   a0, 0x100 + \n
    la   t0, tohost
    sw   a0, 0(t0)
    j    done
  .endm

  .section .text.init
  .globl _start
_start:
  // 1: ctz t1,t1 on 0 -- expect 64
  li   t1, 0
  .word 0x60131313          // ctz  t1, t1
  li   t2, 64
  beq  t1, t2, 1f
  FAIL 1
1:
  // 2: clz t1,t1 on 0 -- expect 64
  li   t1, 0
  .word 0x60031313          // clz  t1, t1
  li   t2, 64
  beq  t1, t2, 2f
  FAIL 2
2:
  // 3: ctzw t1,t1 on 0 -- expect 32
  li   t1, 0
  .word 0x6013131b          // ctzw t1, t1
  li   t2, 32
  beq  t1, t2, 3f
  FAIL 3
3:
  // 4: clzw t1,t1 on 0 -- expect 32
  li   t1, 0
  .word 0x6003131b          // clzw t1, t1
  li   t2, 32
  beq  t1, t2, 4f
  FAIL 4
4:
  // 5: Zbb strlen boundary -- orc.b / not / ctz, expect 8
  // "earlycon" = 0x6e6f63796c726165 (all 8 bytes nonzero).
  li   t1, 0x6e6f63796c726165
  .word 0x28735313          // orc.b t1, t1
  not  t1, t1
  .word 0x60131313          // ctz   t1, t1
  srli t1, t1, 3            // bit count / 8 -> byte index of first NUL
  li   t2, 8
  beq  t1, t2, 5f
  FAIL 5
5:
  // 6: NUL at byte 7 -- "earlyco\0" = 0x006f63796c726165, expect 7
  li   t1, 0x006f63796c726165
  .word 0x28735313          // orc.b t1, t1
  not  t1, t1
  .word 0x60131313          // ctz   t1, t1
  srli t1, t1, 3
  li   t2, 7
  beq  t1, t2, 6f
  FAIL 6
6:
  // pass
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
done:
  j    done

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost:
  .dword 0
  .align 6
  .globl fromhost
fromhost:
  .dword 0
