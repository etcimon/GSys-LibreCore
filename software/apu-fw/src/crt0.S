/* Copyright 2026 Etienne Cimon
 * SPDX-License-Identifier: MIT
 */
  .section .text.init, "ax"
  .globl _start
_start:
  la sp, __stack_top
  /* auipc can leave bits 63:32 set; fwram in_win is 64-bit. */
  slli sp, sp, 32
  srli sp, sp, 32
  call main
1:
  j 1b
