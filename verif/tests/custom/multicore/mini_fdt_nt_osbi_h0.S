# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# S1: same namelen trampoline as mini_fdt_nt_osbi.S but hart1 parks
# (WFI, no store-spin). Isolates whether b1-nt-nl pin is hart1
# occupancy. Warmup on hart0 kept. Same ld / pin VAs.

  .option rvc
  .section .text.init
  .globl _start
_start:
  csrr t0, mhartid
  bnez t0, hart1
  li   sp, 0x80046ef0
  la   t0, trap
  csrw mtvec, t0
  jal  warmup
  li   t0, 0x8001e000
  lbu  t1, 0(t0)
  li   t2, 0xd0
  bne  t1, t2, fail13
  mv   a0, t0
  li   a1, 0
  la   a2, propname
  li   a3, 11
  li   a4, 0x80046f2c
  sw   zero, 0(a4)
  jal  osbi_namelen
  li   a0, 1
  la   t0, tohost
  sw   a0, 0(t0)
1: j    1b

# Hart1: park. No stores — do not fight the 1-entry g1ao_hold PA.
hart1:
  wfi
  j    hart1

warmup:
  li   t0, 800
  li   t1, 0x80045e00
  li   t4, 0x80046e00
3:
  sd   t0, 0(t1)
  sd   t0, 8(t1)
  sd   t0, 0(t4)
  sd   t0, 0x20(t4)
  sd   t0, 0x38(t4)
  ld   t2, 0(t1)
  ld   t3, 0x38(t4)
  addi t0, t0, -1
  bnez t0, 3b
  ret

fail13:
  li   a0, 13
  j    fail_exit
fail_exit:
  la   t0, tohost
  sw   a0, 0(t0)
2: j    2b

trap:
  csrr t0, mepc
  li   t1, 0x80012eb2
  bne  t0, t1, 4f
  li   a0, 27
  j    fail_exit
4:
  li   a0, 25
  j    fail_exit

  .section .text.osbi, "ax"
  .align 1
  .globl osbi_offset_ptr
osbi_offset_ptr:
  .incbin "verif/tests/custom/multicore/osbi_nt/offset_ptr.bin"
  .globl osbi_next_tag
osbi_next_tag:
  .incbin "verif/tests/custom/multicore/osbi_nt/next_tag.bin"
  .globl osbi_check_node
osbi_check_node:
  .incbin "verif/tests/custom/multicore/osbi_nt/check_np.bin"

  .section .text.byoff, "ax"
  .globl osbi_by_offset
osbi_by_offset:
  .incbin "verif/tests/custom/multicore/osbi_nt/by_offset.bin"

  .section .text.gstr, "ax"
  .globl osbi_get_string
osbi_get_string:
  li   a0, 0
  ret

  .section .text.namelen, "ax"
  .globl osbi_namelen
osbi_namelen:
  .incbin "verif/tests/custom/multicore/osbi_nt/namelen.bin"

  .section .dtb, "a"
  .incbin "verif/tests/custom/multicore/osbi_nt/dtb.bin"

  .section .jtab, "a"
  .incbin "verif/tests/custom/multicore/osbi_nt/jtab.bin"

  .section .data
  .align 3
lenp:
  .word 0
nextoff:
  .word 0
propname:
  .asciz "compatible"

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
