/* Copyright 2026 Etienne Cimon */
/* SPDX-License-Identifier: MIT */
/* 3d-a Venus probe: text at the DRAM base the core boots from; queues
 * and tape buffers stay at fixed DRAM offsets owned by the TB ABI
 * (queues 0x80000+, tape payloads 0x4000+), so the program lives from
 * 0x20000 upward and never overlaps them. */

OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS {
  . = 0x80020000;
  .text : {
    *(.text.init)
    *(.text*)
  }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) *(.sdata*) }
  .bss : {
    . = ALIGN(8);
    _bss_start = .;
    *(.bss*) *(.sbss*) *(COMMON)
    . = ALIGN(8);
    _bss_end = .;
  }
  . = ALIGN(16);
  _stack_top = 0x80090000;
}
