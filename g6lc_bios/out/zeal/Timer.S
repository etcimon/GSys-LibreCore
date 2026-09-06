/* generated from g6b-asm IR — do not hand-edit */
.option norvc

/* purpose=timer home=sie+sstatus+SBI-TIME */
	/* TimerInit rewrite: sie.STIE + sstatus.SIE + SBI TIME (RISC-V Priv ch3) */
.globl TimerInit
TimerInit:
	li	t0, 0x20
	csrrs	zero, sie, t0
	li	t0, 2
	csrrs	zero, sstatus, t0
	rdtime	a0
	li	t0, 0x14585
	add	a0, a0, t0
	li	a6, 0
	li	a7, 0x54494d45
	ecall
	ret
