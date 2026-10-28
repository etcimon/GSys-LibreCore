# r84 — load_unit rank-1: `LoadExPubStages` (ex_pub through r51 pend record)

Goal: cut the into-L5 37.2 same-cycle exception publish. Under
`HypCfg.LoadExPubStages == 2` (`localparam LU_EXPEND`), `ex_pub` no
longer presents; the same-cycle kill pushes the r51 pending record
(`ex_pend_set` already subsumes ex_pub's predicate — the record is
dead-on-arrival today because the slot pops the same edge) and
`a_pend`/`ex_pend_sel` presents it +1 cycle. Contract: fault path
+1 cycle only; ==1 bit-identical.

Key facts found:
- `ex_pub` ⇒ `rresp_idx == ldbuf_last_id_q` (ex_i.valid && SEND_TAG
  ⇒ kill_send ⇒ kill_req_w ⇒ the `!kill_req_w` alternative is dead)
  → `pend_new.slot` needs no muxing.
- Tombstone automatic: `rkill_q[rresp_idx] <= (rresp_idx==last_id) &&
  kill_req` (L541) fires under every ex_pub; `drn_ok` frees the slot.
- `pub_ok`/`drn_ok` suppression: `pub_ok` reads `!ex_pend_q &&
  !rkill_q` — both land at the push edge → the pushed slot cannot
  publish as data.
- `pend_rdy_d` needs the live `data_rvalid` OR: `rpend_q[rresp_idx]`
  lands at the same edge as the push, so without it the record would
  present at +2.
- `pend_cnt` depth = NrLoadBufEntries; ≤1 record per slot
  (`ex_pend_q` per-slot bit) → capacity bounded by construction, no
  overflow possible beyond existing coverage.
b52a9c2f24220da520a71954f8491e6b7fa2c3c05ad2a517441a63f5cc0bf2bd *r84-param-map.json
406fc99f5e2304675c6b1eee978995581d3fb26aac637ba8aec7cc9aea4a164b *r84-param-map-deep.json

## r84 — implementation + verification

**RTL** (kept for lead review):
- `g6lc_hyp_pkg.sv`: `LoadExPubStages` (HypDefault=1, Hyp8=1,
  Hyp8Deep=2), `inside {1,2}`.
- `load_unit.sv`: `LU_EXPEND`; `ex_pend_set` |= `LU_EXPEND && ex_pub`
  (explicit — already subsumed); `pend_rdy_d` `live_rpend_oh` gated to
  `LU_EXPEND && ex_pub` (+1 present, deferred timing unchanged);
  `a_expub`/`a_data`/`a_drn`/`valid_o`/`ex_o.valid`/`trans_id_o`/
  `ldbuf_r`/`ldbuf_rindex` wrap every `a_expub` read as
  `LU_EXPEND ? 0/1 : a_expub`; `G6LC_MUT_LU_EXPEND_DROP` on the rkill
  write; `lu_exp_push` assert + `lu_exp_push_n`/`pres_n` counters +
  `[equiv] expend`; `lu_l5_onehot_eq` gated `!LU_EXPEND`.
- `tb_g6lc_hyp8_memory.sv`: F1/F2 +1 tick under `==2`; I1 order swap
  (under ==2 the data arm wins the kill cycle, the record presents
  next — `I1_DATA_FIRST`/`I1_EX_NEXT`).

**Verification**: lint 0/0 both profiles; plain leaf PASS 160 bit-
identical (F15 n=1); deep leaf PASS 160 + `expend pushed=3 presented=4`;
`G6LC_MUT_LU_EXPEND_DROP` fails `LU_MIS_FREED` (slot leak).

**Analyzer work (delay-v47)**: `node_read_symbols`/with_guards in
`compose_module_paths` now use `Expr::walk_read_idents(seed)` — dep
edges fold dead ternary arms. `IR/delayer` at delay-v47.

**Board limitation (escalate)**: `analyze-r84-lu1`/`lu2` both 37.2 —
the `paths[]` builder enumerates REGION nodes (`lower.rs:712`
`node_ids` = all region ops), not dep-chains — `ex_pub`'s node stays
on `out0` regardless of read folding. The delay-v47 dep-edge fold is
necessary but not sufficient: the measurement needs region paths as
dep-chains (or dead-node pruning) before this change class shows on
a board. Keep/revert decision is with the lead — the RTL is
functionally verified but the board gate cannot distinguish it.

## r84 close — batch-end remote verification

- `hyp8-r84-closure`: 732 files (no new files).
- `hyp8-integration-r84b` (`HYP8_ALLOW_OVERLAP=1`; first dispatch hit
  `build_blocked_by_overlap`): `build_complete`, model sha
  `c1f33aa93daeb533e7c415d3c782d4760e3bca16`, lint scalar/smt2 rc=0,
  0 %Error.
- `hyp8-r84-smokes`: 7/7 PASS, cycle-identical
  `685/1011/492/2364/2199/1231/671`.
- `hyp8-integration-r84d` (`HYP8_BUILD_TARGET=g6lc64_hyp8_deep`):
  `build_complete`, sha `c5d0a4f4bbf1fb2c249edcf12b167ea1b4a03bca`,
  lint 0/0.
- `hyp8-r84d-smokes`: 7/7 PASS, **cycle-identical**
  `685/1011/492/2364/2199/1231/671` — no exception on the smoke paths,
  so the +1 fault-path latency is invisible there.

Analyzer finding for the next sv-timing pass: `paths[]` enumerate
region nodes (`lower.rs` `node_ids` = all region ops), not
dep-chains — the delay-v47 `walk_read_idents` dep-edge fold can't
remove a dead-arm assign from a region path. Next item: dep-chain
region paths or dead-node pruning (see `sv-timing/AGENTS-todo.md`).
