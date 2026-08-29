/* SPDX-License-Identifier: MIT
 * ai_island_queue_smoke.S — model-driven AI-island queue-instruction smoke.
 *
 * This payload uses the design's own queue instructions (ai.enq, ai.qfence, ai.poll)
 * instead of the MMIO descriptor-latch window.  All offsets, encodings, and geometry
 * come from the ingested TargetModel via C preprocessor macros.
 *
 *   AI_DESC_ADDR      full guest address of the in-memory descriptor
 *   AI_DONE_PTR       guest DRAM address of the completion word
 *   AI_OFF_M          byte offset of m in the descriptor
 *   AI_OFF_N          byte offset of n in the descriptor
 *   AI_OFF_K          byte offset of k in the descriptor
 *   AI_OFF_PTR_DONE   byte offset of ptr_done in the descriptor
 *   AI_OP_GEMM        numeric op value for GEMM from the design's table
 *   AI_VERSION        descriptor version
 *   AI_ENQ_MATCH      32-bit encoding of ai.enq with rs1=0, rd=0
 *   AI_POLL_MATCH     32-bit encoding of ai.poll with rs1=0, rd=0
 *   AI_QFENCE_MATCH   32-bit encoding of ai.qfence
 *   UART_BASE         full MMIO address of the NS16550a UART
 */

/*
 * Fail the *assembly*, with a readable message, when the model did not publish a value
 * this payload needs. Without these the assembler emits a wall of "illegal operands"
 * lines and the real cause (an un-ingested instruction encoding) is invisible.
 */
#ifndef AI_ENQ_MATCH
#error "AI_ENQ_MATCH undefined: the model has no ingested ai.enq encoding"
#endif
#ifndef AI_POLL_MATCH
#error "AI_POLL_MATCH undefined: the model has no ingested ai.poll encoding"
#endif
#ifndef AI_QFENCE_MATCH
#error "AI_QFENCE_MATCH undefined: the model has no ingested ai.qfence encoding"
#endif
#ifndef AI_DESC_ADDR
#error "AI_DESC_ADDR undefined: the model has no ingested descriptor size"
#endif
#ifndef AI_DONE_PTR
#error "AI_DONE_PTR undefined: no completion pointer was supplied"
#endif
#ifndef AI_OFF_PTR_DONE
#error "AI_OFF_PTR_DONE undefined: the descriptor layout has no ptr_done field"
#endif

/*
 * Sentinel pre-loaded into the completion word. The island must overwrite it, so a
 * completion path that never writes `ptr_done` is caught instead of passing because the
 * word happened to already hold a plausible value (zero is a legal completion word).
 */
#define AI_DONE_SENTINEL 0x5A5A5A5A5A5A5A5A

.section .text
.global _start
_start:
    la sp, _stack_top

    /* Build the descriptor in guest memory.  a0 (x10) is the descriptor pointer
     * so the queue instruction reads the same register it set up. */
    li a0, AI_DESC_ADDR

    li t1, ((AI_VERSION << 16) | (AI_OP_GEMM & 0xffff))
    sw t1, 0(a0)

#ifndef AI_M
#define AI_M 1
#endif
#ifndef AI_N
#define AI_N 1
#endif
#ifndef AI_K
#define AI_K 1
#endif

    li t1, AI_M
    sw t1, AI_OFF_M(a0)
    li t1, AI_N
    sw t1, AI_OFF_N(a0)
    li t1, AI_K
    sw t1, AI_OFF_K(a0)

    li t2, AI_DONE_PTR
    sd t2, AI_OFF_PTR_DONE(a0)

    /* Poison the completion word so "never written" is distinguishable from "wrote 0". */
    li t4, AI_DONE_SENTINEL
    sd t4, 0(t2)

    /* ai.enq t0, a0  ->  t0 (x5) = ticket, a0 (x10) = descriptor address */
    .word (10 << 15) | (5 << 7) | AI_ENQ_MATCH

    /* ai.qfence  ->  complete all in-flight entries */
    .word AI_QFENCE_MATCH

    /* ai.poll x6, x5  ->  x6 = completion word for ticket x5 */
    .word (5 << 15) | (6 << 7) | AI_POLL_MATCH

    /* 1. The entry must not still be pending. */
    li t3, 0xffffffff
    beq x6, t3, fail

    /* 2. The island must have overwritten the sentinel at ptr_done. */
    ld t5, 0(t2)
    beq t5, t4, fail

    /* 3. The word returned by ai.poll must equal the word written to ptr_done, i.e. the
     *    register path and the memory path must agree on the completion-word packing. */
    bne t5, x6, fail

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

1:
    wfi
    j 1b

fail:
    li t6, UART_BASE
    li a0, 'A'
    sw a0, 0(t6)
    li a0, 'I'
    sw a0, 0(t6)
    li a0, '_'
    sw a0, 0(t6)
    li a0, 'N'
    sw a0, 0(t6)
    li a0, 'G'
    sw a0, 0(t6)
    li a0, '\n'
    sw a0, 0(t6)

2:
    wfi
    j 2b
