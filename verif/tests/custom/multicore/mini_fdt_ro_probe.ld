/* SPDX-License-Identifier: MIT */
OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text : {
    *(.text.init)
    *(.text)
  }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  .uvmif : { *(.uvmif) }

  . = 0x8001e000;
  .dtb : { *(.dtb) }

  . = ALIGN(0x10);
  .data : { *(.data) }
  .sdata : {
    __global_pointer$ = . + 0x800;
    *(.srodata*) *(.sdata .sdata.* .gnu.linkonce.s.*)
  }
  .bss : { *(.bss) }
  _end = .;
}
