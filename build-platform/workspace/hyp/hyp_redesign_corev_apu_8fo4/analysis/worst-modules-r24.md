# r24 — worst non-GEMM modules: exact operator narrowing

Board of record on the frozen r20 analyzer (delay-v45 / ir-v6):
`boards/ai-island/analyze-ai-hyp-r24.{json,ir.json,log,manifest.json}`.
Edits by `analysis/tools/r24_edit.py` plus the per-lane product rewrite in
`g6lc_ai_pe_dot.sv`.

| Module | r23 | r24 | Transform |
|---|---:|---:|---|
| `g6lc_ai_pe_dot` | 128.37 | **45.80** | per-lane 8x8 / dual 4x4 products in a 16-bit context as continuous assigns, valid/format as masks; the tree only sums |
| `g6lc_ai_policy_codec` | 85.80 | **59.30** | "six or more zero bytes" as "at most two nonzero bytes" (clear lowest set bit twice), asserted equal to `policy_sparse_residue` |
| `g6lc_ai_policy_subcode` | 80.26 | 78.92 | `(2^r + 2^c) * bytes` as two shifts and an add (mod 2^16) |
| `g6lc_ai_exec` | 62.55 | 62.55 | narrowing the scale operand measured 63.55 and was reverted |

Island ranking after r24: subcode 78.92, desc_engine 63.35, exec 62.55,
codec 59.30, inval_queue 52.25, pe_dot_float_pipe 50.77, gemm_seq 48.70,
pe_dot_float 47.14, fp32_norm 46.25, pe_dot 45.80.

Evidence: remote `ai-gemm-r24-second-r1` (15 GEMM cases including the
DPF=0 arm that instantiates `g6lc_ai_pe_dot`) passes; the policy pipeline
bench passes locally (topology 5568, publications 23, cancels 29). The
subcode/codec changes are arithmetic identities; no new latency. Not run:
the island DMA bench and any exec (cvxif) bench — exec is unchanged.

Remaining owners: subcode's cost/service bundle (row-byte shifts and
service clamps, 78.92), desc_engine's `ai_bus_len` on the check pointer
(63.35; registering per-pointer lengths needs the SPAN→CHK timing confirmed),
exec's 48-bit scale multiply (62.55; a sequential multiplier like
`g6lc_ai_mul_seq` fits its three-phase window), inval_queue's AW last-byte
arithmetic (52.25). Structural maxima, not STA; no 8-FO4 closure.
