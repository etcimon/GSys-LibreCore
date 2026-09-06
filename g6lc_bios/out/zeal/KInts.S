/* generated from g6b-asm IR — do not hand-edit */
.option norvc

/* purpose=trap home=scause */
	/* supervisor trap: irq 5 TIME, irq 9 PLIC (UART 1 RX / mbox); else INT_FAULT — PLIC irq 3; UART irq 1; scause interrupt-bit + code 5 (Priv ch3) */
.globl trap
trap:
	addi	sp, sp, -64
	sd	t0, 0(sp)
	sd	t1, 8(sp)
	sd	t2, 16(sp)
	sd	a0, 24(sp)
	sd	a1, 32(sp)
	sd	a2, 40(sp)
	sd	a6, 48(sp)
	sd	a7, 56(sp)
	csrr	t0, scause
	csrr	t1, sepc
	srli	t2, t0, 63
	beqz	t2, trap_fault
	andi	t2, t0, 31
	li	a2, 5
	beq	t2, a2, trap_timer
	li	a2, 1
	beq	t2, a2, trap_ssi
	li	a2, 9
	bne	t2, a2, trap_fault
trap_sei:
	/* supervisor external interrupt → PLIC claim/complete (not x86 EOI) */
	slli	t1, tp, 1
	addi	t1, t1, 1
	slli	t1, t1, 12
	la	t0, 0xc200004
	add	t0, t0, t1
	lw	t2, 0(t0)
	beqz	t2, trap_done
	sw	t2, 0(t0)
	li	t1, 0xa
	beq	t2, t1, trap_uart
	/* virtio-mmio PLIC source: irq 16 + mmio slot */
	la	t0, __vio
	lw	t1, 1008(t0)
	beqz	t1, trap_done
	li	a2, 0x10001000
	sub	t1, t1, a2
	srli	t1, t1, 12
	addi	t1, t1, 1
	beq	t2, t1, trap_vio
	/* virtio-input PLIC source: irq 1 + input slot */
	lw	t1, 1016(t0)
	beqz	t1, trap_done
	li	a2, 0x10001000
	sub	t1, t1, a2
	srli	t1, t1, 12
	addi	t1, t1, 1
	beq	t2, t1, trap_inp
	j	trap_done
trap_uart:
	/* PLIC irq 1 ns16550 RX + linebuf View/Reboot (not a poll, not 0x3F8) */
	la	t0, 0x10000000
	lbu	t1, 5(t0)
	andi	t1, t1, 1
	beqz	t1, trap_done
	lbu	a0, 0(t0)
	j	uart_take
uart_take:
	mv	t2, a0
	li	a7, 1
	ecall
	la	t0, __uart_line
	lw	t1, 128(t0)
	li	a2, 0xa
	beq	t2, a2, uart_line_go
	li	a2, 0xd
	beq	t2, a2, uart_line_go
	li	a2, 0x80
	beq	t1, a2, trap_done
	add	a1, t0, t1
	sb	t2, 0(a1)
	addi	t1, t1, 1
	sw	t1, 128(t0)
	j	trap_done
uart_line_go:
	lw	a1, 0(t0)
	lbu	t1, 0(t0)
	sw	zero, 128(t0)
	li	a2, 0x77656956
	beq	a1, a2, uart_view
	li	a2, 0x6f626552
	beq	a1, a2, uart_reboot
	li	a2, 0x74756853
	beq	a1, a2, uart_shutdown
	li	a2, 0x656b6157
	beq	a1, a2, uart_wakeup
	li	a2, 0x52
	beq	t1, a2, uart_reboot
	li	a2, 0x53
	beq	t1, a2, uart_shutdown
	li	a2, 0x57
	beq	t1, a2, uart_wakeup
	li	a2, 0x6955
	beq	a1, a2, uart_ui
	li	a2, 0x55
	beq	t1, a2, uart_ui
	li	a2, 0x656c6946
	beq	a1, a2, uart_file
	li	a2, 0x46
	beq	t1, a2, uart_file
	li	a2, 0x746547
	beq	a1, a2, uart_get
	li	a2, 0x47
	beq	t1, a2, uart_get
	li	a2, 0x7379654b
	beq	a1, a2, uart_keys
	li	a2, 0x4b
	beq	t1, a2, uart_keys
uart_view:
	li	a0, 0x56
	li	a7, 1
	ecall
	li	a0, 0x49
	li	a7, 1
	ecall
	li	a0, 0x45
	li	a7, 1
	ecall
	li	a0, 0x57
	li	a7, 1
	ecall
	/* ViewSection("name") — print VIEW name (HolyC REPL rewrite) */
	li	t1, 0
view_findq:
	li	a2, 0x80
	beq	t1, a2, view_nl
	add	a1, t0, t1
	lbu	a2, 0(a1)
	addi	t1, t1, 1
	beqz	a2, view_nl
	li	a0, 0x22
	bne	a2, a0, view_findq
	li	a0, 0x20
	li	a7, 1
	ecall
view_copy:
	li	a2, 0x80
	beq	t1, a2, view_nl
	add	a1, t0, t1
	lbu	a0, 0(a1)
	addi	t1, t1, 1
	beqz	a0, view_nl
	li	a2, 0x22
	beq	a0, a2, view_nl
	li	a7, 1
	ecall
	j	view_copy
view_nl:
	li	a0, 0xa
	li	a7, 1
	ecall
	j	trap_done
uart_ui:
	li	a0, 0x55
	li	a7, 1
	ecall
	li	a0, 0x49
	li	a7, 1
	ecall
	li	a0, 0xa
	li	a7, 1
	ecall
	/* Ui → DomPaint: re-dump live __ui_dom rows (bounded) */
	jal	ra, DomPaint
	/* Ui → VioPaint: push repainted plane to the virtio-gpu scanout */
	jal	ra, VioPaint
	j	trap_done
uart_file:
	/* FileServe("/ui") — HolyC kernel file server rewrite */
	jal	ra, FileServe
	j	trap_done
uart_get:
	/* Get("/ui/ui.wasm") — mailbox/UART HTTP GET rewrite; not a netdev */
	jal	ra, GetFile
	j	trap_done
uart_keys:
	/* Keys — InpPoll: drain the virtio-input eventq and print queued EV_KEY codes (KEY <hex>) */
	jal	ra, InpPoll
	jal	ra, DomNav
	jal	ra, DomKey
	j	trap_done
uart_wakeup:
	li	a0, 0x57
	li	a7, 1
	ecall
	li	a0, 0x41
	li	a7, 1
	ecall
	li	a0, 0x4b
	li	a7, 1
	ecall
	li	a0, 0x45
	li	a7, 1
	ecall
	li	a0, 0xa
	li	a7, 1
	ecall
	j	trap_done
uart_reboot:
	li	a7, 0x53525354
	li	a6, 0
	li	a0, 1
	li	a1, 0
	ecall
	j	trap_done
uart_shutdown:
	li	a7, 0x53525354
	li	a6, 0
	li	a0, 0
	li	a1, 0
	ecall
	j	trap_done
trap_vio:
	lw	t1, 1008(t0)
	lw	a0, 96(t1)
	sw	a0, 100(t1)
	lw	a0, 1012(t0)
	addi	a0, a0, 1
	sw	a0, 1012(t0)
	j	trap_done
trap_inp:
	lw	t1, 1016(t0)
	lw	a0, 96(t1)
	sw	a0, 100(t1)
	/* jal InpDrain — clobbers ra like the DomPaint trap call; the parked/WFI context keeps ra dead */
	jal	ra, InpDrain
	jal	ra, DomNav
	jal	ra, DomKey
	j	trap_done
trap_ssi:
	/* supervisor software interrupt — SBI IPI wake from wfi */
	j	trap_done
trap_timer:
	/* supervisor timer interrupt → rdtime + SBI TIME set_timer */
	rdtime	a0
	li	t0, 0x14585
	add	a0, a0, t0
	li	a6, 0
	li	a7, 0x54494d45
	ecall
	j	trap_done
trap_fault:
	/* recoverable probe: scause 5/7 + stval in UART1/mbox window → absent flag + sepc+4; everything else is the TRAP dump + park */
	srli	t2, t0, 63
	bnez	t2, tf_dump
	andi	t2, t0, 31
	li	a2, 5
	beq	t2, a2, tf_probe
	li	a2, 7
	bne	t2, a2, tf_dump
tf_probe:
	csrrs	a2, 0x143, zero
	la	t2, 0x10009000
	sub	t2, a2, t2
	srli	t2, t2, 4
	beqz	t2, tf_u1
	la	t2, 0x10100000
	sub	t2, a2, t2
	srli	t2, t2, 5
	beqz	t2, tf_mb
	j	tf_dump
tf_u1:
	la	t2, __uart_line
	li	a0, 1
	sb	a0, 132(t2)
	j	tf_skip
tf_mb:
	la	t2, __uart_line
	li	a0, 1
	sb	a0, 133(t2)
tf_skip:
	addi	t1, t1, 4
	csrrw	zero, 0x141, t1
	j	trap_done
tf_dump:
	li	a0, 0x54
	li	a7, 1
	ecall
	li	a0, 0x52
	li	a7, 1
	ecall
	li	a0, 0x41
	li	a7, 1
	ecall
	li	a0, 0x50
	li	a7, 1
	ecall
	li	a0, 0x2d
	li	a7, 1
	ecall
	li	a2, 0x10
hex_scause:
	srli	t2, t0, 60
	andi	t2, t2, 15
	slli	t0, t0, 4
	la	a6, hexdig
	add	a6, a6, t2
	lbu	a0, 0(a6)
	li	a7, 1
	ecall
	addi	a2, a2, -1
	bnez	a2, hex_scause
	li	a0, 0x2d
	li	a7, 1
	ecall
	mv	t0, t1
	li	a2, 0x10
hex_sepc:
	srli	t2, t0, 60
	andi	t2, t2, 15
	slli	t0, t0, 4
	la	a6, hexdig
	add	a6, a6, t2
	lbu	a0, 0(a6)
	li	a7, 1
	ecall
	addi	a2, a2, -1
	bnez	a2, hex_sepc
	li	a0, 0xa
	li	a7, 1
	ecall
trap_halt:
	wfi
	j	trap_halt
hexdig:
	.word	858927408
	.word	926299444
	.word	1650538808
	.word	1717920867
trap_done:
	ld	t0, 0(sp)
	ld	t1, 8(sp)
	ld	t2, 16(sp)
	ld	a0, 24(sp)
	ld	a1, 32(sp)
	ld	a2, 40(sp)
	ld	a6, 48(sp)
	ld	a7, 56(sp)
	addi	sp, sp, 64
	sret

/* purpose=file-serve home=g6ui+html|js|wasm */
	/* FileServe — echo \0asm at G6UI+24, nfiles at +28; print /ui paths (not a VFS) */
.globl FileServe
FileServe:
	la	t0, __ui_blob
	ld	t1, 16(t0)
	beqz	t1, fileserve_list
	lw	t2, 0(t1)
	sw	t2, 24(t0)
fileserve_list:
	li	t1, 3
	sw	t1, 28(t0)
	/* FILE /ui/index.html /ui/app.js /ui/ui.wasm */
	li	a0, 0x46
	li	a7, 1
	ecall
	li	a0, 0x49
	li	a7, 1
	ecall
	li	a0, 0x4c
	li	a7, 1
	ecall
	li	a0, 0x45
	li	a7, 1
	ecall
	li	a0, 0xa
	li	a7, 1
	ecall
	li	a0, 0x2f
	li	a7, 1
	ecall
	li	a0, 0x75
	li	a7, 1
	ecall
	li	a0, 0x69
	li	a7, 1
	ecall
	li	a0, 0x2f
	li	a7, 1
	ecall
	li	a0, 0x69
	li	a7, 1
	ecall
	li	a0, 0x6e
	li	a7, 1
	ecall
	li	a0, 0x64
	li	a7, 1
	ecall
	li	a0, 0x65
	li	a7, 1
	ecall
	li	a0, 0x78
	li	a7, 1
	ecall
	li	a0, 0x2e
	li	a7, 1
	ecall
	li	a0, 0x68
	li	a7, 1
	ecall
	li	a0, 0x74
	li	a7, 1
	ecall
	li	a0, 0x6d
	li	a7, 1
	ecall
	li	a0, 0x6c
	li	a7, 1
	ecall
	li	a0, 0xa
	li	a7, 1
	ecall
	li	a0, 0x2f
	li	a7, 1
	ecall
	li	a0, 0x75
	li	a7, 1
	ecall
	li	a0, 0x69
	li	a7, 1
	ecall
	li	a0, 0x2f
	li	a7, 1
	ecall
	li	a0, 0x61
	li	a7, 1
	ecall
	li	a0, 0x70
	li	a7, 1
	ecall
	li	a0, 0x70
	li	a7, 1
	ecall
	li	a0, 0x2e
	li	a7, 1
	ecall
	li	a0, 0x6a
	li	a7, 1
	ecall
	li	a0, 0x73
	li	a7, 1
	ecall
	li	a0, 0xa
	li	a7, 1
	ecall
	li	a0, 0x2f
	li	a7, 1
	ecall
	li	a0, 0x75
	li	a7, 1
	ecall
	li	a0, 0x69
	li	a7, 1
	ecall
	li	a0, 0x2f
	li	a7, 1
	ecall
	li	a0, 0x75
	li	a7, 1
	ecall
	li	a0, 0x69
	li	a7, 1
	ecall
	li	a0, 0x2e
	li	a7, 1
	ecall
	li	a0, 0x77
	li	a7, 1
	ecall
	li	a0, 0x61
	li	a7, 1
	ecall
	li	a0, 0x73
	li	a7, 1
	ecall
	li	a0, 0x6d
	li	a7, 1
	ecall
	li	a0, 0xa
	li	a7, 1
	ecall
	ret

/* purpose=http home=h1+h2 parse */
	/* GetFile — HTTP GET /ui/ui.wasm (guest blob; not a netdev, not a VFS) */
.globl GetFile
GetFile:
	/* GET /ui/ui.wasm */
	li	a0, 0x48
	li	a7, 1
	ecall
	li	a0, 0x54
	li	a7, 1
	ecall
	li	a0, 0x54
	li	a7, 1
	ecall
	li	a0, 0x50
	li	a7, 1
	ecall
	li	a0, 0x2f
	li	a7, 1
	ecall
	li	a0, 0x31
	li	a7, 1
	ecall
	li	a0, 0x2e
	li	a7, 1
	ecall
	li	a0, 0x31
	li	a7, 1
	ecall
	li	a0, 0x20
	li	a7, 1
	ecall
	li	a0, 0x32
	li	a7, 1
	ecall
	li	a0, 0x30
	li	a7, 1
	ecall
	li	a0, 0x30
	li	a7, 1
	ecall
	li	a0, 0xa
	li	a7, 1
	ecall
	li	a0, 0x47
	li	a7, 1
	ecall
	li	a0, 0x45
	li	a7, 1
	ecall
	li	a0, 0x54
	li	a7, 1
	ecall
	li	a0, 0x20
	li	a7, 1
	ecall
	li	a0, 0x2f
	li	a7, 1
	ecall
	li	a0, 0x75
	li	a7, 1
	ecall
	li	a0, 0x69
	li	a7, 1
	ecall
	li	a0, 0x2f
	li	a7, 1
	ecall
	li	a0, 0x75
	li	a7, 1
	ecall
	li	a0, 0x69
	li	a7, 1
	ecall
	li	a0, 0x2e
	li	a7, 1
	ecall
	li	a0, 0x77
	li	a7, 1
	ecall
	li	a0, 0x61
	li	a7, 1
	ecall
	li	a0, 0x73
	li	a7, 1
	ecall
	li	a0, 0x6d
	li	a7, 1
	ecall
	li	a0, 0xa
	li	a7, 1
	ecall
	ret

.section .bss
__uart_line:
.space 0x88
__ui_blob:
.space 0x20
