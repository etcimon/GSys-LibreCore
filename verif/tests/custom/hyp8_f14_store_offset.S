# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# hyp8 F14 discriminator (mechanism resolved r76): rvfi_tracer's
# end_of_test fires on the reported mem_paddr, and RVFI's mem_paddr was
# the speculative STQ HEAD at commit time — not the committing
# instruction's own paddr. Under OoO issue the final `sw -> tohost`
# sits in the STQ behind the still-uncommitted sc.d, so the sc.d's
# commit presented mem_paddr=tohost with mem_wdata=0xAD (bit0 set) ->
# the harness declared "tohost = 0xAD" and stopped the sim before the
# sw ever drained (no AW to 0x80001000 exists on any probe). An
# observer defect in RVFI paddr attribution, not memory corruption —
# the AW/W path is correct at every stage (verified +f14_trace).
# This test still discriminates the write path once the attribution
# is right.
#   tohost = 1   both paths wrote where the architecture wrote
#   tohost = 76  (raw 0x99) the plain store already lands at tohost -> the
#                defect is the store / DRAM / SBA path, not the exclusive one
#   tohost = 86  (raw 0xAD) the sc.d lands at tohost -> SC-specific owner
#   3            the plain store's own readback mismatched
# Kept as a regression for both the write path and the attribution fix.
#   tohost = 1   both paths wrote where the architecture wrote
#   tohost = 76  (raw 0x99) the plain store already lands at tohost -> the
#                defect is the store / DRAM / SBA path, not the exclusive one
#   tohost = 86  (raw 0xAD) the sc.d lands at tohost -> SC-specific owner
#   3            the plain store's own readback mismatched
.option norvc
.section .text.init
.globl _start
_start:
  la    a5, lockq
  li    a4, 0x99
  sd    a4, 0(a5)            # plain store, same address class as the sc.d
  fence
  ld    t3, 0(a5)
  li    t4, 0x99
  bne   t3, t4, fail
  la    a6, lockr
  li    a4, 0xAD
  lr.d  a3, (a6)
  sc.d  a7, a4, (a6)         # exclusive store, addr[8:6] != 0
  fence
  bne   a7, zero, fail
  li    t0, 1
  la    t1, tohost
  sw    t0, 0(t1)
  j     done
fail:
  li    t0, 3
  la    t1, tohost
  sw    t0, 0(t1)
done:
  j     done

.section .data
.align 6
data:
  .dword 0, 0, 0, 0, 0, 0, 0, 0
  .dword 0, 0, 0, 0, 0, 0, 0, 0
  .dword 0, 0, 0, 0, 0, 0, 0, 0
.align 6
lockq: .dword 0              # 0x...1140-class offset (data+0xC0)
.align 6
lockr: .dword 0              # next 64 B slot

.section .tohost,"aw",@progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
