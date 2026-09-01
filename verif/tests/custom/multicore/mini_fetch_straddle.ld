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

  . = 0x80012000;
  .text.straddle : { *(.text.straddle) }

  . = ALIGN(0x10);
  .data : { *(.data) }
  .sdata : {
    __global_pointer$ = . + 0x800;
    *(.srodata*) *(.sdata .sdata.* .gnu.linkonce.s.*)
  }
  .bss : { *(.bss) }
  _end = .;
}
