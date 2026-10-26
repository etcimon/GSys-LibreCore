# r56 — load_unit publish-port / state_d census (pre board analyze-r55.json 75fd8a1d)

## Path census

| FO4 | kind | locus | endpoint | class_note |
|-----|------|-------|----------|------------|
| 41.05 | regtoout | :1360 | out0 | independent-LHS bundle lhs=8 writes=18..23 max_field=14.5 makespan=41.0 cycles=6 next_state — the r51 publish-port arbitration (accepted structural debt) |
| 35.05 | regtoout | :1360 | out0 | **plain** — `state_q→state_d` step 33.5; P10 handshake lock note |
| 33.50 | regtoreg | :1046 | reg1/D | `state_d` unique-case arms=29 max_arm=15.3 crit=15.3 raw 466→15.3; **dependency floor makespan=33.5 (deps=31) > deflated 15.3**; chain L1216(7.x)>… |
| ~26 | intoout | (take/grant cones) | out0 | take-grant → take-output cones (already split r52-B5 in iq_arb; load_unit's own take arm) |

The real cone is the `state_d` unique-case FSM (`always_comb` at ~:1046-1360): 29 arms,
15.3 FO4 of arm logic, but a **31-deep intra-block dependency floor** — arms read
`pub_any`, `ex_pend_sel`, `pend_pop`, `pend_state_ok`, `rpend_q`, `fwd_final`,
`ldbuf_q[j]` fields, `valid_i`, `req_port_i.data_rvalid`, `st_pipeline_busy`,
`ex_i.valid/cause` etc., several of which are themselves block-internal signals or
downstream of the same case. The r51 additions (`pend_state_ok`, `ex_pend_sel`,
`pend_pop`, `pub_oh`/`drn_oh` prefix-OR, `pub_ptree`/`drn_itree` masked-OR trees)
all live in or feed this block's fan-in.

## Candidates (logic-equivalent, no latency change, r51 semantics preserved)

**C1 — B1-class predicate hoist (recommended).** Lift the *input-derived* shared
predicates out of the case into module wires so no arm recomputes them and the
analyzer stops treating them as intra-case reads:
- `req_port_i.data_rvalid`, `req_port_i.kill_req` → `d_rvalid`, `kill_req` wires
- `st_pipeline_busy` (already partially), `valid_i`, `ex_i.valid`, `ex_i.cause==…`,
  `fwd_final`, `flushed_d[j]`, `cancelled_mask_i[tid]` slices used by >1 arm
- the `(rd_ack_i && req_port_i.data_req)`-style pair terms if any repeat across arms
Keep `pend_state_ok`/`ex_pend_sel`/`pend_pop`/`pub_oh`/`drn_oh`/`pub_ptree` exactly
as-is (already wires/assigns; r51 semantics untouched). Expected: cuts the dep
floor below ~24 FO4 (dcache_ctrl r54 analogue: 28.57→24.02 with the same shape).

**C2 — publish-output split (only if C1 leaves >~28).** The `out0` bundle mixes
`valid_o`/`trans_id_o`/`rdata_o`/`ex_o` publish fields with `state_d`/`pop_ld_o`/
`lu_replay_o`/`miss_req_o` FSM fields. Split the block into two `always_comb`:
(a) `state_d` + flow-control outputs, (b) the publish-port payload/valid fields
driven from `ex_pend_sel`/`pub_oh`/`pub_ptree`/`pub_idx_w`. Both cones bill
separately (the iq_arb r52-B5 precedent cut 33.85→32.85 this way). Risk: the
publish fields and `state_d` share `pub_any`/`pend` terms — the shared wires must
stay module-scope, not block-local.

## Non-goals
No change to `ex_pend_*`/`rpend_*`/`rkill_*` semantics (r51 contract), no new
pipeline stage, no change to `pend_state_ok`'s state set or the strict
ex-priority order.

## Estimate
C1: ~8-11 FO4 off the 35.05 plain path (target ≤ ~26). C2: additional ~2-4 if the
out0 bundle splits cleanly. Both revertable byte-exactly.
