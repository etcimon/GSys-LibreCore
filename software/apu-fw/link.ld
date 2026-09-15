/* SPDX-License-Identifier: MIT
 * Resident APU firmware: ApuHarness FirmwareRamBase 0x90000000 / 256 KiB.
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x90000000;
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
  __stack_top = 0x9003F000;
}
