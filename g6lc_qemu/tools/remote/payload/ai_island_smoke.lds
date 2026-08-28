/* SPDX-License-Identifier: MIT
 * ai_island_smoke.lds — link the M-mode smoke payload at 0x80000000.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS {
    . = 0x80000000;
    .text : { *(.text) }
    .bss : { *(.bss) }
    _stack_top = 0x81000000;
}
