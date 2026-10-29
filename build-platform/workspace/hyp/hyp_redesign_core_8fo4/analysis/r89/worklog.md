## r89 — three RTL reductions (load_unit ex_pend, rename_read ckpt_slot, g6lc_lsq lane_be)

All on `build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/` only.
Board of record: `analysis/timing/boards/r89-all.json` (delay-v49,
r88-param-map, 283 modules, 12630 paths); top-26 `boards/r89-top.txt`.
Runners: `analysis/r89/run_hyp8_review_local.sh` (extracted review tops)
and `analysis/r89/run_hyp8_lsq_local.sh` (hyp8_lsq leaf, needs
`-DG6LC_HYP8_LSQ_LEAF`).

### A. load_unit — ex_pend_set reads next-cycle flush vector
`core/load_unit.sv` ~L596: `ex_pend_slot_live` applies the ex_pub
reduction — on a valid slot `!flushed_d` ≡ `!flushed_q && !flush_i &&
!cancelled_mask_i[ldbuf_q[last].trans_id]` (LDBUF_FALLTHROUGH keeps the
full form); `ex_pend_set` uses it; translate_off equivalence assert.
- Gate: `run_hyp8_mem_local.sh` plain `HYP8_MEMORY_PASS checked=160`;
  deep `-DG6LC_HYP8_DEEP` `HYP8_MEMORY_PASS checked=160` +
  `expend pushed=3 presented=4`. No assertion fires.
- Board: 54.5 regtoreg L626 -> **47.1 regtoreg L1462** (-7.5).
  New top: `ex_pub(10.5) -> a_expub(3.4) -> a_data(4.0) -> a_drn(3.0)
  -> ldbuf_rindex(3.0) -> ldbuf_valid_d[ldbuf_rindex](6.5)` — the
  `flushed_d` prefix left the pend path.

### B. g6lc_rename_read — ckpt_slot billed at 32-bit int width
`core/ooo/g6lc_rename_read.sv` ~L74+: `CPH_W`/`CPH_POW2`/`SUM_W`/`SB_CNT_W`
localparams; `ckpt_slot_n` (pow2 slice / SUM_W subtract loop);
`sb_cnt` narrowed to SB_CNT_W; `ck_sum` = head+cnt+sb at SUM_W; `do_ckpt`
and `br_over` compares at SUM_W; `ckpt_slot` kept under translate_off
with per-lane `p_ckpt_eq` immediate assert.
- Gate: `tb_g6lc_review_rename` builds and runs but asserts
  `RENAME_NO_ALLOC` at scenario 0 — identical on pre- and post-edit
  trees (pre-existing tb-vs-tree mismatch, not this edit).
  `tb_g6lc_review_ckpt`/`ckptrand` cannot build under stock
  Verilator 5.020: V3ParseSym bug on `x.field=…` inside the
  `configuration()` function (`function automatic config_pkg::cva6_cfg_t`
  and `c.NrHarts=` member writes; the full file fails at the same bug
  class in `tb_g6lc_review_fp_lifetime`'s task code, L177).
- Board: 54.1 intoout L292 -> **51.0 intoout L220** (-3.1). New top:
  `taken_lt(5.0) -> lone_p(32.0) -> alloc_ok(1.0) -> alloc_do(1.0) ->
  lane_o[gp].prd(12.0)` — the 46.6-node ckpt_slot cone is off the
  top path.

### C. g6lc_lsq — lane_be barrel under the vv_* guards
`core/ooo/g6lc_lsq.sv` ~L470: `LANE_BE_TAB` constant table
(`lane_be_table()`, 32 slots over `{size,a[2:0]}`); `lane_be` is a
table lookup; `lane_be_ref` + `lane_be_tab_chk` initial-block assert
under translate_off; `ev_be[u]`/`q_be` hoisted as continuous assigns
(same pattern as `s_be[s]`/`ev0_be`); `sbe`/`lbe` temporaries removed.
- Gate: `tb_g6lc_hyp8_lsq` (with `-DG6LC_HYP8_LSQ_LEAF`) fatals at
  [185] in `g6lc_lsq_reduce`'s `g6lc_lsq_red_age_miter` (pre-existing
  r53-B6 oracle divergence, `mask=00010010 oh_s=1/4 d=0c/0d`) —
  identical on pre- and post-edit trees; `lane_be_tab_chk` fired no
  error at time 0. `tb_g6lc_review_lsq` cannot build under
  Verilator 5.020 (same parser bug as ckpt).
- Board: 54.5 intoreg L531 -> **36.8 intoout L350** (-17.7). New top:
  `ld_free_o + 1'b1` (32.8) in an independent-lhs bundle (5-cycle
  class note); the `sbe`/`lbe` barrel terms are gone.

### Delta (r88 -> r89, board top rows)
| module            | r88  | r89  | delta |
|-------------------|------|------|-------|
| g6lc_rename_read  | 54.1 | 51.0 | -3.1  |
| load_unit         | 54.5 | 47.1 | -7.5  |
| g6lc_lsq          | 54.5 | 36.8 | -17.7 |

No other module row moved (top-20 all +0.0). Remaining gates the
review-top protocol could not run are recorded above; nothing reverted.
`g6lc_rename_recover.sv:123` has its own `ckpt_slot` copy (out of scope).
