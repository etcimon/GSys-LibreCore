## r90-ai — g6lc_ai_exec requant 2-phase + 9x9 MMA product

`core/cvxif_g6lc_ai/g6lc_ai_exec.sv` (hyp8 tree only).

### (a) ST_RQ_R two-phase split
`rq_t_rnd` ternary -> `rq_t_q + 48'(rq_bump)` (bump as add operand);
new `rq_r_ph_q` toggles in ST_RQ_R / held 0 outside; phase 0 captures
`rq_adj_q[31:0] <= rq_adj[31:0]` (only low 32 bits feed rq_wz); phase 1
runs today's body (rq_wz/rq_hi/rq_lo parallel - rq_byte priority was
already exclusive - tile write + (m,n)/state advance). rq_* inputs
load in ST_RQ/ST_RQ_S - stable across both phases. translate_off:
`rq_byte_ref` (one-cycle formula) + `rq_ph_chk` (`rq_adj_q == 32'(rq_adj)`,
`rq_byte == rq_byte_ref`) at phase 1.

### (b) MMA lane 9x9 product + F17
`mac_a9_q`/`mac_b9_q` (9-bit `{sgn & b[7], b}`) captured at ph 0 per
dtype (a_sgn = 00|10, b_sgn = 00|11); `p18` = 9 Baugh-Wooley rows
(row[i<8] masked sext18(a9)<<i, row[8] sign weight -(sext18<<8))
reduced 9->6->4->3 via csa3 + one 18-bit add; `mac_prod_q <=
{32{mac_use_q}} & 32'(signed'(p18))`. The four dtype multiply arms
(including the F17 U8xU8 16'-truncating arm - 200*200 = -25536) are
replaced; translate_off `mac_prod_chk` asserts `p18 == a9*b9`.

### Board
`boards/r90-ai.json`: **90.4 -> 79.5** in_to_reg (L479 -> L814; the
`mac_prod_q` 82.6 cone is gone). New top: dot4 `ba -> sa_ext ->
rs[bi](18.1) -> ps(17.0) -> dot4_s_p` (L325-338). mac_prod_q hot-node
cost pending (the 18-bit product bills ~10-14 vs the four-arm 82.6).

### Gates
NOT RUN - context exhausted by the RTL; the translate_off identity
asserts (`rq_ph_chk`, `mac_prod_chk`) are live for the leaf runs.
`tb_g6lc_ai_enq_ready`/`tb_g6lc_ai_exec_dot` + U8 extension are the
remaining gate work for the next pass.
