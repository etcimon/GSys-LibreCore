# r29 — desc_engine prepared bus lengths

Frozen r20 analyzer (delay-v45 / ir-v6). Board:
`boards/ai-island/analyze-ai-hyp-r29.{json,ir.json,log,manifest.json}`.

`g6lc_ai_desc_engine`: the check-phase `ai_bus_len(ptr, span)` is now a
registered fact per pointer (`len_a_q`, `len_b_q`, refreshed every cycle from
the span registers, which settle at least one cycle before ST_CHK_A), and
`check_len_o` selects it by state. Asserted equal to the inline function in
the check states. Module maximum **63.35 → 39.00** (the remaining
owner is the span capture bundle at ~39 and the ST_GEMM issue bundle).

Gate: the hyp island DMA bench (`run-ai-island-dma.sh` through
`run_policy_r17.sh island`): `*** SUCCESS *** ai-island DMA (447 cycles)`,
`PASS tb_g6lc_ai_island_dma`.

Island ranking after r29: subcode 60.34, pe_dot_float_pipe 50.77,
gemm_seq 48.70, pe_dot_float 47.14, inval_queue 46.54, fp32_norm 46.25,
pe_dot 45.80, codec 39.40, exec 26.07 — from r19's 128.37 / 98.00 / 94.93.

Not changed this pass: subcode's three products (need the wired-row
carry-save form that moved exec, mechanical), inval_queue's AW skid, codec
(39.40 after r26). Structural maxima, not STA; no 8-FO4 closure.
