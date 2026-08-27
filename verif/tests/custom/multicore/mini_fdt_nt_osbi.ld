/* SPDX-License-Identifier: MIT
 * Stock OpenSBI FDT helpers at pin VAs (holes are unused).
 */
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

  . = 0x800128e8;
  .text.osbi : { *(.text.osbi) }

  . = 0x80012e26;
  .text.byoff : { *(.text.byoff) }

  . = 0x80012eba;
  .text.gstr : { *(.text.gstr) }

  . = 0x80013040;
  .text.namelen : { *(.text.namelen) }

  . = 0x8001e000;
  .dtb : { *(.dtb) }

  . = 0x800224c0;
  .jtab : { *(.jtab) }

  . = ALIGN(0x10);
  .data : { *(.data) }
  .sdata : {
    __global_pointer$ = . + 0x800;
    *(.srodata*) *(.sdata .sdata.* .gnu.linkonce.s.*)
  }
  .bss : { *(.bss) }
  _end = .;
}
