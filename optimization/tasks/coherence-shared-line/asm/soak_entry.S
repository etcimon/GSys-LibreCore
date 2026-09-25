# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Verilator soak entry for the optimization kernels. Link with one kernel,
# `-e soak_start` and `-Wl,--defsym=kernel_entry=<symbol>` naming the kernel's
# entry (`_start` or `main`): every hart calls it, and it returns its status in
# a0 (0 = pass). Hart 0 publishes the verdict through tohost:
#
#   pass:  tohost = (mark_cycles << 4) | 0x3   -- low nibble 3, cycles above
#   fail:  tohost = (status << 4) | 0x1        -- low nibble 1, status above
#   trap:  tohost = (mcause << 4) | 0x5        -- low nibble 5, cause above
#
# fesvr treats every odd value other than 1 as a failure exit and prints it in
# full, so the runner decodes the nibble and the payload from the log; a run
# that reaches the cycle bound prints tohost = 0 and is never a pass. Kernels
# other than hart 0 park after returning; the kernel must not depend on a stack.

  .option norvc
  .section .text.soak,"ax",@progbits
  .globl soak_start
soak_start:
  la   t0, soak_trap
  csrw mtvec, t0
  call kernel_entry
  csrr t0, mhartid
  bnez t0, soak_park
  bnez a0, soak_fail
  la   t0, mark_cycles
  ld   t1, 0(t0)
  slli t1, t1, 4
  ori  t1, t1, 0x3
  j    soak_exit
soak_fail:
  slli t1, a0, 4
  ori  t1, t1, 0x1
soak_exit:
  la   t0, tohost
  sd   t1, 0(t0)
soak_park:
  wfi
  j    soak_park
soak_trap:
  csrr t1, mcause
  slli t1, t1, 4
  ori  t1, t1, 0x5
  csrr t0, mhartid
  bnez t0, soak_park
  j    soak_exit

  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
