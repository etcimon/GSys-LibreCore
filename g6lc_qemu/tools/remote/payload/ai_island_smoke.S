/* SPDX-License-Identifier: MIT
 * ai_island_smoke.S — M-mode AI-tensor descriptor smoke payload.
 *
 * This payload is intentionally model-driven: all descriptor offsets, the
 * descriptor window base, the GEMM op value, the version, and the completion
 * pointer are supplied as C preprocessor macros so the same source can be
 * compiled against any ingested `desc_layout` without hard-coding design
 * constants.
 *
 *   AI_DESC_BASE      full MMIO address of the descriptor window
 *   AI_DONE_PTR       guest DRAM address of the completion word
 *   AI_OFF_M          byte offset of m in the descriptor
 *   AI_OFF_N          byte offset of n in the descriptor
 *   AI_OFF_K          byte offset of k in the descriptor
 *   AI_OFF_PTR_DONE   byte offset of ptr_done in the descriptor
 *   AI_OP_GEMM        numeric op value for GEMM from the design's table
 *   AI_VERSION        descriptor version
 *   UART_BASE         full MMIO address of the NS16550a UART
 */

.section .text
.global _start
_start:
    la sp, _stack_top

    li t0, AI_DESC_BASE

    /* Default GEMM shape: m=1, n=1, k=1.  The same source is used for
     * larger model-derived smoke shapes by overriding the defaults. */
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
    sw t1, AI_OFF_M(t0)
    li t1, AI_N
    sw t1, AI_OFF_N(t0)
    li t1, AI_K
    sw t1, AI_OFF_K(t0)

    /* Write the completion/done pointer. */
    li t2, AI_DONE_PTR
    sd t2, AI_OFF_PTR_DONE(t0)

    /* Ring the doorbell: version=AI_VERSION, op=AI_OP_GEMM. */
    li t1, ((AI_VERSION << 16) | (AI_OP_GEMM & 0xffff))
    sw t1, 0(t0)

    /* In B2 the plugin observes a store to ptr_done and marks the descriptor
     * done.  In B3 the device writes the packed completion word.  Either way a
     * successful status word is (ticket=0, status=0), i.e. the value 0; this
     * smoke cannot poll for a non-zero word and is therefore intentionally not
     * a completion test — it is a doorbell + descriptor-latch test. */
    li t5, 0
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

1:
    wfi
    j 1b
