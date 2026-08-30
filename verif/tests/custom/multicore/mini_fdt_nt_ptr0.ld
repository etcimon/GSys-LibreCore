/* Verilator bare-metal layout for s4-v-ptr0.
 * The fixed VAs reproduce the S4 failure class (mepc=0 / ra=0x80012994).
 * SPDX-License-Identifier: MIT
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  _start_text = .;
  .text : {
    *(.text.init)
    *(.text)
    *(.text.startup)
  }
  _end_text = .;

  /* HTIF tohost / uvmif early so the Verilator DTM and exit_o agree. */
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  .uvmif : { *(.uvmif) }

  /* Test wrapper: 32-bit RVI straddle, jal offset_ptr, c.jr a0 */
  . = 0x80012980;
  .text.ptr0 : { *(.text.ptr0) }

  /* libfdt fdt_offset_ptr, relocated from osbi_nt/offset_ptr.bin */
  . = 0x80013000;
  .text.offset : { *(.text.offset) }

  /* Minimal FDT + stub */
  . = 0x8001e000;
  .text.fdt : { *(.text.fdt) }

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
  .tbss : { *(.tbss) }
  _end = .;
}
