/* Verilator bare-metal: compact layout, no page align between text and tohost.
 * SPDX-License-Identifier: Apache-2.0
 */
OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  _start_text = .;
  .text : {
    *(.text.init)
    *(.text .text.*)
    *(.text.startup)
  }
  _end_text = .;
  /* Keep HTIF data well clear of I$ prefetch past code (16 KiB I$). */
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  .uvmif : { *(.uvmif) }
  .rodata : { *(.rodata*) }
  .data : { *(.data) }
  .sdata : {
    __global_pointer$ = . + 0x800;
    *(.srodata*) *(.sdata .sdata.* .gnu.linkonce.s.*)
  }
  .bss : { *(.bss) }
  .tdata : {
    _tdata_begin = .;
    *(.tdata)
    _tdata_end = .;
  }
  .tbss : {
    *(.tbss)
    _tbss_end = .;
  }
  _end = .;
}
