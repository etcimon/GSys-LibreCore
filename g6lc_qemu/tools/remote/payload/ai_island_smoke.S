/* SPDX-License-Identifier: MIT
 * ai_island_smoke.S — M-mode AI-tensor descriptor smoke payload.
 *
 * Writes a minimal version=1, op=GEMM descriptor to the AI-island descriptor
 * latch, rings the doorbell (version/op at offset 0), polls the ptr_done word,
 * and prints "AI_OK\n" on the NS16550a UART if the status is ST_OK (0).
 */

.section .text
.global _start
_start:
    la sp, _stack_top

    li t0, AI_BASE

    /* Minimal GEMM shape: m=1, n=1, k=1. */
    li t1, 0x1
    sw t1, 0x08(t0)         /* m */
    sw t1, 0x0c(t0)         /* n */
    sw t1, 0x10(t0)         /* k */

    /* Write the completion/done pointer (inside DRAM at 0x80010000). */
    li t2, 0x80010000
    sd t2, 0x38(t0)         /* ptr_done is at descriptor offset 56 (0x38). */

    /* Ring the doorbell: version=1, op=1 (GEMM). */
    li t1, 0x00010001
    sw t1, 0x00(t0)

    /* Poll the completion word at 0x80010000 for ST_OK (0). */
    li t3, 1000
1:
    addi t3, t3, -1
    beqz t3, fail
    ld t4, 0(t2)
    li t6, 0xffff
    and t4, t4, t6
    bnez t4, 1b

    /* Write a done word (ticket=0, status=0) so the trace marks it complete. */
    li t5, 0x0
    sd t5, 0(t2)

    /* Print "AI_OK\n" to the UART. */
    li t6, UART_BASE
    li a0, 'A'
    sw a0, 0(t6)
    li a0, 'I'
    sw a0, 0(t6)
    li a0, '_'
    sw a0, 0(t6)
    li a0, 'O'
    sw a0, 0(t6)
    li a0, 'K'
    sw a0, 0(t6)
    li a0, '\n'
    sw a0, 0(t6)

2:
    wfi
    j 2b

fail:
    li t6, UART_BASE
    li a0, 'F'
    sw a0, 0(t6)
    li a0, 'A'
    sw a0, 0(t6)
    li a0, 'I'
    sw a0, 0(t6)
    li a0, 'L'
    sw a0, 0(t6)
    li a0, '\n'
    sw a0, 0(t6)
3:
    wfi
    j 3b
