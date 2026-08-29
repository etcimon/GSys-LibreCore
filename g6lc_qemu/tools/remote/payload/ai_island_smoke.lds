/* SPDX-License-Identifier: MIT
 * ai_island_smoke.lds — link the M-mode smoke payload at 0x80000000.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS {
    . = 0x80000000;
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) *(COMMON) }
    _stack_top = 0x81000000;

    /*
     * Without this, a *Linux-targeting* cross compiler (riscv64-linux-gnu-gcc) emits
     * .interp/.dynamic/.note and has to place the ELF program headers in a LOAD segment.
     * With .text pinned to the start of DRAM there is no room in front of it, so the
     * linker puts the segment one page *below* DRAM base (0x7ffff000). QEMU then reports
     * `image_low_addr` outside RAM, the payload never lands, and the reset vector jumps
     * into unmapped memory — a silent hang with no output at all.
     *
     * `objcopy -O binary` hides the problem because it discards everything but .text,
     * which is why the `.bin` path worked while `-kernel <elf>` did not. A bare-metal
     * toolchain (riscv-none-elf-gcc) also hides it by not emitting these sections.
     */
    /DISCARD/ : {
        *(.interp)
        *(.dynamic)
        *(.dynsym)
        *(.dynstr)
        *(.hash)
        *(.gnu.hash)
        *(.gnu.version*)
        *(.note*)
        *(.comment)
        *(.riscv.attributes)
        *(.eh_frame*)
    }
}
