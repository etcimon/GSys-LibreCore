/* generated from g6b-asm IR — do not hand-edit */
.option norvc

/* purpose=wasm-jit home=wasm MVP */
	/* WASM-JIT i32.add → add a0, a0, a1 (svelte-d / libwasm numeric leaf) */
.globl wasm_add_i32
wasm_add_i32:
	addi	sp, sp, -16
	add	a0, a0, a1
	sw	a0, 0(sp)
	lw	a0, 0(sp)
	addi	sp, sp, 16
	ret
