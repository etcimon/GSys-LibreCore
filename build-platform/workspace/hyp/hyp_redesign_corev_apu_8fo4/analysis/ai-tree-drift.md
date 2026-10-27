# ai-tree-drift — hyp overlay vs production AI island/ai-matrix drift census

Census for ai-fo4-program §3 batch 1 step (a), 2026-10-26. Method:
`diff --strip-trailing-cr -U0` per file pair; `+N` = production-only lines,
`-N` = hyp-only lines. Classification: **hyp-rework** = the delta is the
sv-timing emit / manual FO4 rewrite (hyp longer); **prod-feature** = a real
functional feature production has and hyp lacks (named); **both**;
**identical**; **prod-only** = file absent in hyp.

Scope: `hyp_redesign_corev_apu_8fo4/corev_apu/{ai_island,src/g6lc_ai_*,
include/g6lc_ai_island_cfg_pkg.sv}` + `hyp_redesign_core_8fo4/core/cvxif_g6lc_ai/`
vs `corev_apu/` and `core/cvxif_g6lc_ai/` (production, tier R).

## corev_apu/ai_island (23 hyp files, 27 production)

| file | hyp/prod lines | +prod/-hyp | class | note |
|---|---|---|---|---|
| g6lc_ai_addr_check.sv | 135/101 | +1/-35 | hyp-rework | prod line is an equivalent `always_ff` header articulation |
| g6lc_ai_axi_cut.sv | 63/62 | +0/-1 | hyp-rework | header only |
| g6lc_ai_cap_window.sv | 192/166 | +1/-27 | hyp-rework | |
| g6lc_ai_cluster_dispatch.sv | 541/329 | +1/-213 | hyp-rework | |
| g6lc_ai_cmd_fifo.sv | 135/94 | +1/-42 | hyp-rework | |
| g6lc_ai_cpl_fifo.sv | 155/106 | +1/-50 | hyp-rework | |
| g6lc_ai_desc_engine.sv | 484/415 | +3/-72 | hyp-rework | `busy_o` / `ai_beat_lo` arg form — same construct, different articulation |
| g6lc_ai_desc_fetch.sv | 234/179 | +1/-57 | hyp-rework | |
| g6lc_ai_dram_timing.sv | 198/130 | +1/-69 | hyp-rework | |
| g6lc_ai_enq_arb.sv | 100/78 | +1/-23 | hyp-rework | |
| **g6lc_ai_gemm_seq.sv** | 3446/2748 | +94/-792 | **both** | prod-only = r68 **DotPipeInt** plumbing (parameter, `gen_pe_int_comb`/`gen_pe_int_pipe_only`, `DotPipeAny`/`DOT_LATENCY`, `dot_valid_f/i`, `dot_sum_i`, `pe_float_en`, `dot_pipe_en`, `gen_dot_pipe_float`) + `axi_req_o` articulation; to be ported per batch-1 (d) |
| g6lc_ai_inval_queue.sv | 271/193 | +1/-79 | hyp-rework | |
| g6lc_ai_island_apb.sv | 191/169 | +1/-23 | hyp-rework | |
| g6lc_ai_island_top.sv | 2155/1713 | +1/-443 | hyp-rework | prod line is `cap_sel` assign — same construct |
| g6lc_ai_mem_store.sv | 207/164 | +1/-44 | hyp-rework | |
| g6lc_ai_pe_dot.sv | 176/165 | +1/-12 | hyp-rework | prod line is `always_comb` header articulation; hyp carries balance-mux credit comments |
| g6lc_ai_pe_dot_float.sv | 209/208 | +0/-2 | hyp-rework | |
| g6lc_ai_pe_dot_float_pipe.sv | 732/411 | +1/-323 | hyp-rework | |
| **g6lc_ai_pe_dot_pipe.sv** | 228/228 | — | **identical** | sha 2362054e…; the batch-1 (d) B1/B2 item lands here first |
| g6lc_ai_policy_codec.sv | 284/249 | +1/-36 | hyp-rework | |
| g6lc_ai_policy_steer.sv | 227/205 | +1/-23 | hyp-rework | |
| g6lc_ai_policy_subcode.sv | 511/277 | +1/-235 | hyp-rework | |
| g6lc_ai_tile_sram.sv | 277/276 | +0/-2 | hyp-rework | |
| g6lc_ai_cluster_set.sv | —/prod | — | **prod-only** | copy per closure step (b) |
| g6lc_ai_cluster_tile.sv | —/prod | — | **prod-only** | copy per closure step (b) |
| g6lc_ai_fp_dot.sv | —/prod | — | **prod-only** | copy per closure step (b) |
| g6lc_ai_fp_mac.sv | —/prod | — | **prod-only** | copy per closure step (b) |

## corev_apu/src/g6lc_ai_*.sv

`g6lc_ai_dram_backend.sv`, `g6lc_ai_dram_channels.sv`, `g6lc_ai_dram_join.sv`,
`g6lc_ai_litedram_wrap.sv`: **identical** (0-hunk diffs).

## corev_apu/include/g6lc_ai_island_cfg_pkg.sv

1193/1193 lines, 1 hunk, comment-only: hyp comment says `g6lc_cfg_t`, production
`cva6_cfg_t` — naming-era alias, no functional delta.

## core/cvxif_g6lc_ai (hyp_redesign_core_8fo4)

| file | hyp/prod lines | +prod/-hyp | class | note |
|---|---|---|---|---|
| g6lc_ai_acc_bank.sv | 91/90 | +1/-2 | hyp-rework | |
| g6lc_ai_coprocessor.sv | 231/230 | +2/-3 | hyp-rework | |
| g6lc_ai_exec.sv | 993/812 | +148/-329 | hyp-rework | hyp already carries the parallel dot4 (A1 form: `gen_dot4` product array + 4-operand sums), a 5-phase registered-product ST_MMA MAC (`mac_prod_q[TileK]` + `mac_lane_sum` tree), and the ST_RQ/ST_RQ_S/ST_RQ_R 3-state requant split (A4 form, `rq_ph_q` phases). Prod-only lines are the old serial `dot4_s8`/`dot4_u8` functions + inline requant — **not a missing feature** |
| include/g6lc_ai_instr_pkg.sv | identical | — | identical | |

## Adjacent non-AI drift (out of AI scope, noted)

- `corev_apu/include/g6lc_apu_cfg_pkg.sv` (5178/5178): 3 signature sites —
  hyp uses `config_pkg::g6lc_cfg_t`, production `cva6_cfg_t` (alias seam) +
  1 comment (`G6LC` vs `CVA6` fetch). Naming-era only.
- `corev_apu/src` non-AI: `g6lc_axi_atomics_wrap.sv` identical;
  `g6lc_axi_2to1_mux.sv`, `g6lc_axi_lrsc.sv` ±1 line;
  `g6lc_ara_attach.sv` +15/-15, `g6lc_cluster.sv` +95/-99,
  `g6lc_core_hb.sv`/`_pkg.sv` — real hyp/core rework drift, not AI files.
  HYP-ONLY: `g6lc_axi2apb_reg.sv`, `g6lc_axi2mem_reg.sv`, `g6lc_hart.sv`,
  `g6lc_soc.sv`. PROD-ONLY: `ariane.sv`.
- `corev_apu/src/g6lc_cluster.sv` also shows an uncommitted production
  modification in git status (lead-side, not touched here).

## Summary for the batch

- Only functional port owed: **DotPipeInt** (r68) into hyp `gemm_seq` — batch
  step (d).
- Hyp `g6lc_ai_exec` already contains A1 (parallel dot4) and an A4-form
  requant split plus a phased MAC; the A-items reduce to *measurement* first.
- 4 prod-only files to copy byte-exact (closure step (b)): fp_mac, fp_dot,
  cluster_set, cluster_tile.
- Everything else is emit/rework articulation, no merge needed.
