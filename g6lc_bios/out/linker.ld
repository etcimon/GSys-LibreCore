/* Generated linker script: DRAM 0x80000000 len 0x40000000 text_offset 0x200000 XLEN 64 */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
	. = 0x80000000;
	.text : { *(.text.start) *(.text*) }
	.rodata : { *(.rodata*) }
	.data : { *(.data*) }
	.bss : { *(.bss*) }
}
