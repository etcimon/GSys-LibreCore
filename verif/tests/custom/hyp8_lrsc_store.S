# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Liveness of a plain store between LR and SC (legal RISC-V; the SC may
# succeed or fail). v1 stores to another word, v2 to the reserved word (the
# SC must then fail or observe the store), v3 is LR with no SC followed by a
# store. Every variant must complete; a wedge shows as a budget-out.
#
# tohost = 1 on success; (2*k+1) names the first failing variant.
.option norvc
.section .text.init
.globl _start
_start:
  li    s7, 0

# v1: lr.d; sd (other word); sc.d -- must complete, memory consistent
v1:
  la    a5, lockd
  la    a2, other
  li    a4, 0x11
  li    t0, 0x22
  lr.d  a3, (a5)
  sd    t0, 0(a2)
  sc.d  a6, a4, (a5)
  fence
  ld    t3, 0(a2)
  bne   t3, t0, fail1
  ld    t3, 0(a5)
  beqz  a6, 1f               # sc succeeded -> lockd == 0x11
  bnez  t3, fail1            # sc failed    -> lockd unchanged (0)
  j     v2
1:
  bne   t3, a4, fail1
  j     v2
fail1:
  li    s7, 1
  j     report

# v2: lr.d; sd (same word); sc.d -- sc may succeed only after the store
v2:
  la    a5, lockq
  li    a4, 0x33
  li    t0, 0x44
  lr.d  a3, (a5)
  sd    t0, 0(a5)
  sc.d  a6, a4, (a5)
  fence
  ld    t3, 0(a5)
  beqz  a6, 2f
  bne   t3, t0, fail2        # sc failed: the store's value remains
  j     v3
2:
  bne   t3, a4, fail2        # sc succeeded: its value is last
  j     v3
fail2:
  li    s7, 2
  j     report

# v3: lr.d with no sc, then a store -- must complete
v3:
  la    a5, lockr
  la    a2, other
  li    t0, 0x55
  lr.d  a3, (a5)
  sd    t0, 0(a2)
  fence
  ld    t3, 0(a2)
  bne   t3, t0, fail3
  j     report
fail3:
  li    s7, 3

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
lockd: .dword 0
.align 6
lockq: .dword 0
.align 6
lockr: .dword 0
.align 6
other: .dword 0

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
