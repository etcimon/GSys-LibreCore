/* generated from g6b-asm IR — do not hand-edit */
.option norvc

/* purpose=memcpy home=a0,a1,a2 */
	/* ISEL-SCALAR MemCpy — ISel rewrite of Compiler/Back* (xlen=64) */
.globl MemCpy
MemCpy:
	beqz	a2, memcpy_done
memcpy_loop:
	lbu	t0, 0(a1)
	sb	t0, 0(a0)
	addi	a0, a0, 1
	addi	a1, a1, 1
	addi	a2, a2, -1
	bnez	a2, memcpy_loop
memcpy_done:
	ret

/* purpose=reboot home=a7=SRST */
	/* Reboot — SBI SRST (eid 0x53525354); not a PC keyboard-controller reset */
.globl Reboot
Reboot:
	li	a7, 0x53525354
	li	a6, 0
	li	a0, 1
	li	a1, 0
	ecall
	ret
