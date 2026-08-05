/* S-mode payload for OpenSBI FW_PAYLOAD — load above typical OpenSBI runtime.
 * OpenSBI relocates/embeds payload; link address is conventional for bare S-mode
 * tests that are also runnable standalone after OpenSBI jump.
 * SPDX-License-Identifier: MIT
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  /* Below OpenSBI default payload offset within fw_payload; kept simple for
   * embedded payload object path. Standalone link at 0x80200000 (common jump). */
  . = 0x80200000;
  .text : {
    *(.text.init)
    *(.text*)
  }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  .bss : {
    __bss_start = .;
    *(.bss*)
    *(COMMON)
    __bss_end = .;
  }
  . = ALIGN(16);
  __stack_top = . + 0x4000;
}
