# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Directed reproducer for the b1-fdt-lenp-store residual: call the OpenSBI
# fdt_ro_probe_ blob directly with the real DTB and a cache-warmup stack store.
# fdt_ro_probe_ is the function that hangs in OpenSBI at 0x800125d8/0x80012638
# with a5 retaining the FDT base pointer (0x8001e000). If the load unit / D$
# path fails to return the FDT header bytes, this call either hangs or returns
# an error code in a0.

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80046ef0
  la   t0, trap
  csrw mtvec, t0

  # Cache / STQ occupancy like the real OpenSBI path.
  jal  warmup

  # Set up a stack "lenp" like fdt_get_property_namelen_ does and store a
  # non-zero sentinel to it (the value itself is unimportant; the store keeps
  # the wbuffer / STQ busy on a nearby same-set address).
  li   a4, 0x80046f2c
  sw   t0, 0(a4)

  # Call the stock OpenSBI fdt_ro_probe_ with a0 = FDT base.
  li   a0, 0x8001e000
  jal  osbi_ro_probe

  # fdt_ro_probe_ returns 0 on success, negative FDT_ERR_* on validation fail.
  # If the load hangs we never get here and the TB times out with tohost=0.
  beqz a0, pass

  # Return non-zero -> encode a0 as an odd tohost failure code (a0 = value,
  # tohost = (a0 << 1) | 1  if positive, or use the raw negative value).
  mv   t0, a0
  slli t0, t0, 1
  ori  t0, t0, 1
  la   a1, tohost
  sw   t0, 0(a1)
1: j    1b

pass:
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

hart1:
  li   sp, 0x80048000
  li   t1, 0x80047e00
3:
  sd   t1, 0(t1)
  sd   t1, 64(t1)
  ld   t2, 0(t1)
  j    3b

# STQ/D$ occupancy on the TRACE alias line and a same-set neighbour.
warmup:
  li   t0, 800
  li   t1, 0x80045e00
  li   t4, 0x80046e00
4:
  sd   t0, 0(t1)
  sd   t0, 8(t1)
  sd   t0, 0(t4)
  sd   t0, 0x20(t4)
  sd   t0, 0x38(t4)
  ld   t2, 0(t1)
  ld   t3, 0x38(t4)
  addi t0, t0, -1
  bnez t0, 4b
  ret

trap:
  li   a0, 25
  la   t0, tohost
  sw   a0, 0(t0)
5: j    5b

  .section .text.osbi, "ax"
  .align 1
  .globl osbi_ro_probe
osbi_ro_probe:
  .incbin "verif/tests/custom/multicore/osbi_nt/ro_probe.bin"

  .section .dtb, "a"
  .incbin "verif/tests/custom/multicore/osbi_nt/dtb.bin"

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
