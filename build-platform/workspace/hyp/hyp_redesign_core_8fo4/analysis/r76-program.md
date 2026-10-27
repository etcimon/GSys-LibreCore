# r76 — program: caller-purposed stages toward structural 8 FO4, with the Linux retirement path kept sound

Lead-authored 2026-10-27. Sits on top of `r75-fo4-8-program.md` (tiers, pattern card, per-module table),
`r69-fo4-program.md` (P1–P10 designs), `execution-path-plan.md` (the spine: one retirement event, six
visibility channels, the E1–E7 evaluation protocol) and the r1–r75 record in `implementation-log.md`.
It states what r76 **implements**, what it **settles as design** for the next passes, and the evidence
that decides each item. Nothing here is a boot claim, a physical-timing claim or SMT2 evidence; every
FO4 number is structural delay-v44 at the 8.0 budget (5 GHz nameplate, fo4_ps 20, margin 0.2) and is
~3× smaller than the Nangate45 adjusted reading (execution-path-plan §5 honesty gate, A121/A146).

Reasoning lenses applied (read in full before this pass): `AGENTS-coding-philosophy.md` §0 (weigh the
causal links, change only the surviving mechanism), §2.9 (firmware is a witness, contract before change,
push the check left), §2.10 (segment cards); `architecture/multi-threading/AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md`
P1–P7, T1–T10, ladder L0–L7; `architecture/AGENTS-g6lc-opensbi-dev-heuristics.md` H1–H7 (H3 oracle
validity as precondition, H5 blame locality, H6 red-line veto, H7 hatch repayment);
`AGENTS-rt-learning-philosophy-AGI.md` RT-P1..P8 and §4 (a consequence is not proof of its cause; absence
needs an observation guarantee; a plausible owner is not a confirmed cause); `sv-timing/architecture/PIPELINING-RT-LEARNING.md`
PL-P1..P5 ("preserve an operation, not just a wire"; reservation before state update; a candidate must
improve in both views); `sv-timing/ALGORITHMS-EXPERTS.md` A104/A106/A118/A120/A134/A140/A141/A146/A148.
The APU program's development rules (`hyp_redesign_corev_apu_8fo4/analysis/ai-fo4-program.md` §0/§5/§6:
rank 0/1/2, keep-only-on-module-max-drop with byte-exact revert, lint-before-board, one `always_ff` per
register group / one `always_comb` per output family, zip-before-edit, outputs are flops at seams whose
callers consume them in a cone) are carried over verbatim as the method of this pass.

---

## 0. Where the tree stands (inputs to this pass, all from the record)

| Axis | State at r75 |
|---|---|
| Functional | r73/r74 witnesses `r46a` (old fw) / `r46b` (FDT-fixed fw) at 38 M cycles, 7.65 M / 7.64 M retired, no hang; every previously recorded Linux-path barrier (19.47 M, 21.95 M, 22.11 M, 15.69 M / 22.55 M) is behind the kernel on both layouts. UART still OpenSBI-only. Five smokes SUCCESS (685/1011/492/2364/2190). |
| Open functional | **F14** — the `sc.d` AXI write lands with addr[8:6] cleared (0x80001140 → 0x80001000) while a plain `sd` at the same offset class lands correctly (`hyp8_f14_store_offset` → tohost 86, SC-specific); `g6lc_axi_lrsc` and the WT adapter's AW formation exonerated by reading; the pulp `axi_riscv_atomics_wrap` (scalar profile) passes `aw_addr` through unmodified (`axi_riscv_lrsc.sv:323`, `axi_riscv_amos.sv:540`) — so reading alone cannot name the owner; the AXI AW probe run is the discriminator. **mc2** — 4-core/8-hart model never fetches (I$ KILL_MISS at the reset vector, IFILL return lost at cluster level). **8-issue** needs a 128-bit fetch path (`FETCH_ALIGN_BITS==3` pin in `g6lc_icache`). |
| Structural (clock rule, `analyze-r73-all` + r74/r75 edits) | live clock-setter `load_unit` 41.0 (in-stage L5 publish pick); then `g6lc_iq_bank` 32.3 (SEL), `g6lc_rename_recover` 31.8, `g6lc_tlb` 30.9, `g6lc_iq_arb` 30.6, `issue_read_operands` 28.0, `alu` 27.9 (A3), `g6lc_ptw` 27.4, `store_unit` 27.1. Presentation cones the clock rule drops but callers consume in-cycle: `g6lc_iq` 101.7 (steer, stitch into dispatch 125.2), `g6lc_decode_s3` 53.7 / `_s2` 40.8 (bundle floors), `wt_dcache_wbuffer` 50.1, `g6lc_rename_read` 49.6, `instr_queue` 45.1, `aes` 44.9, `store_unit` 42.3, `csr_regfile` 37.4, `g6lc_freelist` 37.1, `g6lc_rename` 35.0, `g6lc_mmu` 33.6, `g6lc_fe_redirect` 33.1. 182 of 258 modules over 8.0. |
| Pattern card (r52–r75) | rank-0 moves are measured out on the top modules (~50 % countercase rate on blind rewrites); every module above 16 needs a register on its limiting cone, above 24 at least two — **stages are now the program**, rank 0 only inside each new stage (r75 §0). |

---

## 1. Method restated for stage work (what every r76 item must satisfy)

```
board(module) → classify limiter (plain / bundle / case / dense / multi-cycle)
  → caller search (instances + cross_module_paths): who consumes the output in the same cycle;
    who may take it one cycle later (latency-tolerant)
  → choose: (a) representation  (b) rank-0 equivalent  (c) stage at a registered seam (A106/A120)
            (d) caller-purpose segment (new module per consumer class)
  → write the ownership table for the new register BEFORE it exists:
      producer event · stored fields · owner · consumer event · stale-reuse rule
    and walk the six visibility channels (P3) for every change to squash/flush/forward/commit
  → config knob in g6lc_hyp_cfg_t + hyp_cfg_ok legality; the 1-stage profile stays bit-identical
  → edit one module → lint → board → keep only on module-max drop, else byte-exact revert
  → leaf for every contract change (+ a mutant that must fail) · smokes · one Linux witness per batch
```

Latency accounting is per dependency (retirement-plan ¶"Latency accounting"): a stage on a dependence
path (load-use, store→load forward, multiply, ALU full-width) lengthens L for every chain through it;
a stage on a *service* path (publish, steer, verdict) costs one cycle once per operation and is hidden
by the window when the consumer is latency-tolerant. r76 therefore spends its stage budget first on
service paths whose callers are tolerant, and leaves dependence paths (IqSelStages, StoreTransStages)
to a later tier with an IPC measurement (E5).

---

## 2. F15 — publish-port collision in `load_unit` (functional, found by abstract trace this pass)

```text
SEGMENT CARD
  QUESTION      Can a data-slot publish and an FSM-head completion claim the single LSU
                writeback port in the same cycle, and what happens to the loser?
  ENVELOPE      hyp8 scalar (OoOEn, NrLoadBufEntries 8, StoreFwdCycles 3, DcacheHitExtra 2);
                source trace of core/load_unit.sv rvalid_output (L1423–1517), no simulation.
  CONTRACT      LU → scoreboard: every slot the load unit pops is presented exactly once as
                {valid_o, trans_id_o, result/ex} (retirement-plan §1: an accepted instruction stays
                represented by exactly one owner until retired or cancelled).
  OBSERVATIONS  (facts) The data arm `else if (pub_any)` sets valid_o/trans_id_o AND pops its slot
                (ldbuf_r/ldbuf_rindex). Three later arms override valid_o/trans_id_o/ex_o.valid
                unconditionally: WAIT_TRANSLATION exception, WAIT_SPEC_LOAD write-off, st_fwd_done
                (IDLE and WAIT_PAGE_OFFSET). Each is guarded by `!req_port_i.data_rvalid`, the
                in-order core's publish==rvalid invariant. Under hyp8 L5 a slot publishes when
                rpend_q && ld_checked_i[tid] — one or more cycles after rvalid, with no relation to
                the FSM head's cycle. The pending-exception arm is protected (pend_state_ok excludes
                the head-arm states); ex_pub requires SEND_TAG (exclusive). pub_any has no gate.
  HYPOTHESIS    H-COLL: on a collision the slot is popped but its completion never presented → the
                scoreboard entry stays issued=1 valid=0 (lost load; the r19 "evaporated load" and
                r40 "SB head LOAD lsu_ready=0" shapes, though those two were attributed elsewhere
                and this is not a reattribution — RT §4.7).
  ALTERNATIVE   H-EXCL: some invariant makes pub_any and a head arm mutually exclusive. Checked:
                st_fwd_done needs valid_i && page_offset_matches_i && st_fwd_covers && ld_checked_head
                — nothing about other slots; the WT exception arm needs a PTW fault on the head —
                nothing about slots. No exclusion found in source.
  DISCRIMINATOR Leaf case F15 (tb_g6lc_hyp8_memory): slot A rpend+checked at t, head B covered at t.
                Expected with the fix: B at t, A at t+1, both presented. Mutant
                G6LC_MUT_LU_PUB_COLLIDE (the old priority) must lose A. Plus the L3 assertion
                `ldbuf_r && pub_fire |-> valid_o && trans_id_o == popped slot's tid` and a counter of
                collision cycles reported on the smokes and the witness (how often it is reachable).
  FIX           Data arm yields (the FSM is untouched): head_pub = OR of the three head-arm
                predicates hoisted into named wires; the data arm fires only when !head_pub; the
                slot keeps rpend and publishes next cycle. Channel walk: 1 no (no write for a
                squashed op is added), 2 closed (the omitted write is the defect), 3/4 unchanged
                (no lifetime change), 5 no (control from validity bits only), 6 unchanged.
  LIMITS        Not credited with any recorded wedge until the counter shows the collision on a
                witness; it is a T7 contract fix (wrong for a program nobody has written).
```

## 3. B1 — `LoadPubStages` (rank 1, the clock-setter)

Mechanism of the 41.0: L5 evaluates `pub_ok` (a dynamic read `ld_checked_i[ldbuf_q[i].trans_id]` per
slot, four qualifiers), the lowest-index prefix, an 8-leaf masked-OR gather of `{meta, 64-bit merged
word}`, then the L4 align/sign-extend and the port priority, in one cycle. The r72 per-family split
reclassified it as dense control (+5) and was reverted; the r64 S1 dedicated exception lane removes
only the ex arms. The remaining lever is the one r75 §4 names: **publish payload registered**.

Design (config `HypCfg.LoadPubStages ∈ {1,2}`; Hyp8 = 1 bit-identical, Hyp8Deep = 2):

| | L5a — select | L5b — present |
|---|---|---|
| Inputs | `pub_ok[i] = rpend ∧ valid ∧ ¬flushed ∧ ¬rkill ∧ ¬ex_pend ∧ ld_checked[tid] ∧ fwd_resolved ∧ ¬claim_q[i]` | `prec_v_q, prec_oh_q, prec_idx_q` |
| Work | prefix lowest-index one-hot | masked-OR gather by a **registered** one-hot; L4 align; port priority |
| Register (ownership) | producer = the select; fields = {v, one-hot, index}; owner = L5b; consumer event = `pub_fire`; stale-reuse rule = the slot is `claim_q`-marked and excluded from re-select until it fires or drops | — |
| Fire | — | `pub_fire = prec_v_q ∧ ¬head_pub ∧ ¬ex_pend_sel ∧ ¬ex_pub ∧ ¬flushed_q[idx] ∧ ¬rkill_q[idx]` |
| Hold | a new select is captured only when `¬prec_v_q ∨ pub_fire` (back-to-back possible) | record holds while outranked |
| Drop | — | `flushed_q[idx] ∨ rkill_q[idx]` → drop record + unclaim; the drain pick frees the slot |

Visibility channels: 1 — a flushed/cancelled slot cannot fire (same registered `flushed_q` qualifier
as today, one cycle later; the scoreboard already tolerates a writeback on the cancel edge); 2 — the
record cannot be lost: it holds until fired or its slot is tombstoned, and a tombstoned slot drains
through `drn_ok` exactly as an unclaimed one; 3 — `flush_i` clears the record at the edge (the slot is
tombstoned the same edge); 4 — nothing live is dropped: drop requires the slot's own tombstone; 5 —
control from validity bits only; 6 — no cross-hart ordering change (publication order among slots is
unchanged: lowest index, one per cycle).

Contract/latency: load WB +1 under `==2` (`hyp_lat_cycles(LAT_LOAD)` and `g6lc_iq` `WAKE_LD` gain
`+(LoadPubStages−1)`; inert under `IqSpecWakeup=0`, kept exact for the retained speculation
machinery); a claimed slot stays allocated one cycle longer (effective load-buffer capacity −1 under
back-to-back publishes; `NrLoadBufEntries=8`). `LD_HIT_LAT` (the H5 miss-replay timer) is rvalid
latency and is unchanged. Expected board: L5 41.0 → L5a ≈ 16–22 (dynamic index + prefix), L5b ≈ 15–22
(3-level gather + align); the module's next limiter is the `state_q → state_d` plain cone (35.0), whose
design is execution-path-plan §5a item 6a (control from `load_pa_v_q` only).

Gates: lint both profiles; boards `analyze-r76-lu` (Hyp8, must equal the F15-only board) and
`analyze-r76-lu-deep`; memory leaf under both profiles (+ F15 case, + mutant); deep-profile
integration build + five smokes; the Hyp8 build's smokes cycle-identical except where the F15 counter
is non-zero.

## 4. B3 — rank-0 per-output-family splits (bundle floors)

`g6lc_decode_s3` 53.7 (58-LHS bundle :275), `g6lc_decode_s2` 40.8, `csr_regfile` 37.4, `g6lc_mmu`
33.6, `g6lc_fe_redirect` 33.1. The analyzer bills one `always_comb` as the makespan of its LHS set
(the P6 finding on `island_top`: 1047.9 → 51.8 by partition alone), so these numbers are floors, not
cones. The split is hand-made per output family with the `unique case`/if skeleton replicated (not a
statement filter — the ai-hyp-r3 D6 lesson), kept only on a measured drop (the `load_unit` split rose
to dense_control and was reverted, r72). Bit-identical by construction; the batch-end smokes must be
cycle-identical.

## 5. C1 — F14 discriminator (harness-side probes, one run)

`[f14]` AW/W/AR probes under `translate_off`, plusarg `+f14_trace`, at (1) `wt_axi_adapter`
`axi_req_o.aw` (with `dcache_data.rtype/amo_op/paddr`), (2) `master[DRAM]` into
`i_axi_riscv_atomics`, (3) `dram` out of it, (4) `dram_lat`, (5) `g6lc_ai_dram_backend` `axi2mem`
`req && we`. The first point at which addr[8:6] differs from the core's `dcache_data.paddr` names the
owner; a core-side difference (point 1) sends the search to the miss unit's `paddrSizeAlign`/`amo_req`
path, a harness-side one to the vendored atomics or `axi2mem`. Test `hyp8_f14_store_offset` on the r76
model (~1100 cycles). No fix is proposed before the probe answers (coding-philosophy §0 step 3: state
what would reject the attribution before collecting the trace).

## 6. Settled designs for the next passes (not implemented in r76; knobs exist after A1)

**B2 `IqSteerStages=2` — latency-neutral early steer (A120 early preparation).** Fact: dispatch is
serialized (`can_go` requires `!grp_pend_q && !(|grp_v_q)`, `g6lc_ooo_dispatch.sv:315-317`), so no
second group can allocate while one is held; between the cycle before `grp_v_q` is set and the
allocation cycle, `bank_free` can only grow (issues free entries). Therefore the first-fit steer can
be evaluated one cycle early from the rename R3 outputs (`ren_group_valid` strobe cycle: lane
validity + hint) and registered at the same edge that latches `grp_*_q`; at the allocation cycle the
IQ uses `asgn_q/fits_q` plus a one-compare-per-lane recheck `bank_free[asgn_q[p]] > used_q[p]` (safe
by construction; an assertion `balloc == 0` in the pre-cycle documents the serialization the design
relies on). Dispatch exposes `steer_pre_valid_o/steer_pre_hint_o` one cycle ahead. Expected: the
101.7 in→out steer cone leaves the allocation cycle; the remaining in→out is `disp_valid → balloc →
bank alloc → back → disp_ack` (~20–30); stitch 125.2 falls accordingly. Latency: none added in the
serialized regime; when dispatch is later pipelined to one group per cycle the recheck becomes the
reservation (PL "reservation before state update"). Gate: dispatch leaf (`HYP8_DISPATCH_PASS`) + smokes.

**B4 `StoreTransStages=2` (r69 P7).** Registers `paddr_i` with `trans_id_q` at the store unit so
`st_valid` presents one cycle after translation; consumers of `page_offset_matches`/`st_fwd` see the
store one cycle later — a load matching in that cycle must wait or replay (the T33 `spec_only`
mechanism exists). Dependence-path cost: store→load forward +1 for the first cycle after translation
only. Needs the memory leaf's forward cases re-timed and an IPC read on `h33`.

**B5 `TlbCtxStages=2` (r75 S4).** Per entry, register the context side of the match (`asid/vmid/
global/level qualification`) at its update edges — entry write and `asid_i`/`vmid_i` change — and
keep the VPN equality live (A134 "cache the state-only side at its update edge"). Obligation: no
lookup may consume `ctx_ok_q` in the cycle `asid_i` changes (a SATP write flushes the pipeline;
assert `!lookup_valid` in that cycle at L3, or mux the live predicate for that cycle only). Exact;
equivalence assertion vs the live predicate.

**B9 `RenameReadStages=2` (r75 §4).** Cycle 1 ckpt slot/count, cycle 2 lane assembly; the r69/r74
late-select countercases (49.6 → 56.1/62.6) show the arm is control, not arithmetic, so the register
is the honest move. Rename +1; `grp_pend_q` serialization note applies (continuation-design ¶).

**P9 `IqSelStages=2`** (rank 2, +1 issue latency for every class; `r47` sticky kill must cover the
new edge; measure IPC on the smokes) — last, after the service-path stages have moved the board.

**mc2 reset fetch** — AXI AR/R probe on the cluster master port at cycle ~2000 (id/addr of the first
NC ifill and whether R returns with that id); candidates in order: hub AXI ID/return routing for NC
reads at `NrCores=4`, bootrom slave under `TARGET_HARTS=8`, the FE reset-redirect kill racing the NC
miss. One probe model, seconds of simulation; the 8-hart build is the cost (3–8 h).

**8-issue fetch** — `FetchWidth=128` through `g6lc_icache` (offset fold, response record), realign
and the instruction queue (`qslots` already separated from packet slots in r72 B); a design item with
its own realign leaf (`HYP8_REALIGN_PASS` family), not a config fix.

## 7. Results (lead, from `analysis/r76/worklog.md`; evidence in implementation-log `## r76`)

| Item | Outcome | Evidence |
|---|---|---|
| A1 config spine | landed; Hyp8 bit-identical (smokes cycle-identical) | lint both profiles 0 new; maps `r76-param-map{,-deep}.json` |
| F15 collision | **real and reachable**; fixed (data arm yields, superset gate F15b) | leaf F15 PASS (checked=160, n=1); mutant fails at 744; smokes n=0, identical cycles |
| B1 `LoadPubStages=2` | **countercase**, reverted (42.0 → 47.0 deep; the 41.0 was a bundle makespan, not a cone) | `analyze-r76-lu{,-deep}.json` |
| L5 one-hot presentation | kept: load_unit **41.0 → 37.2** (block re-bills one-hot, inst 19.2; limiter now into-L5 37.2 / rr 33.5 `state_d`) | `analyze-r76-lu2.json`, `[equiv] L5 onehot checked=155` |
| B3 splits | `g6lc_decode_s3` 53.7 → 52.3 (pres), `g6lc_fe_redirect` 33.1 → 30.0 (pres); `g6lc_mmu`/`decode_s2`/`csr_regfile` deferred | `analyze-r76-ds3.json`, `analyze-r76-fer.json` |
| C1 F14 | **resolved as an RVFI attribution defect** (STQ-head `mem_paddr` at commit under OoO issue); per-instruction paddr capture landed; `hyp8_amo_ready_order` and `hyp8_f14_store_offset` now SUCCESS → **7/7 smokes** | `[f14]` probe lines + tracer evidence line in the worklog; `hyp8-r76e/f-smokes` |
| Batch board | structural clock **0.97 → 1.08 GHz** (41.0 → 37.2 FO4) | `analyze-r76-all.json` |
| Witness | `hyp8-osbi-scalar-r47b` running (100 M budget), no `[hang]` at ~12 M | collect with `testharness_proxy.py pull --tag hyp8-osbi-scalar-r47b` |

Method lessons added to the pattern card: (1) a bundle makespan (`independent_lhs_bundle`, `max_field ≪ makespan`) is resolved by the one-hot/masked-OR presentation form, not by a stage — the stage measured as a countercase on the same block; (2) a correctness gate's *form* matters for timing — gate on registered/port predicates that are a provable superset of the deep decode, and assert the subset relation; (3) before any memory-corruption hypothesis, validate the oracle's field provenance (H3): the tracer's `mem_paddr` was never the instruction's own address under OoO.

Status of the record (T9): every statement from r68 to r74 that treats F14 as a DRAM/atomics/SBA write corruption or as a boot-claim blocker is superseded by this pass; the observations (tohost readings, rvfi `mem` lines) stand, the attribution does not.

## 8. r77 addendum (lead, 2026-10-27)

Three-worst pass on the r76 board (E2 ranking): `g6lc_iq` steer **101.7 → 38.3 pres, stitch into dispatch 125.2 → 54.9** (P6 split + A120 prepared `ge[k]` compares; dispatch leaf `HYP8_DISPATCH_PASS 125`, `[equiv] r69 steer checked=619`; smokes 7/7 identical on `hyp8-integration-r77`); `load_unit` 2(a) NI late-select closed as a false premise (the PMA check is on the page-aligned PPN; r42-T R7a), 2(b) slot-cancel share NULL and reverted; `g6lc_rename_recover` family split NULL (co-limiter `gen_pub_v` :412 at the same 31.8) and reverted. Structural clock stays 1.08 GHz (load_unit 37.2). B2 `IqSteerStages=2` is no longer required for the steer cone (kept on file for pipelined dispatch). Details: implementation-log `## r77`, `analysis/r77/worklog.md`.

## 9. r78 addendum (lead, 2026-10-27) — open list closed; rank-0 exhausted on the top rows

Kept: `g6lc_iq_bank` one_older single-hot table 32.3 → 30.1; `g6lc_tlb` flush-arm match hoist 30.9 → 24.9. Nulls/closed with evidence: rename_recover `gen_pub_v` (three co-limiters at 31.8 → rank-1 two-edge flush repair), load_unit item 6a (census: no state arm reads the 56-bit select → closed; remaining lever = registered NI verdict), iq_bank decode-at-allocation, iq_arb. `hyp8-integration-r78` 7/7 smokes identical; clock 1.08 GHz (load_unit 37.2). Next tier is rank 1 in the order listed in implementation-log `## r78`; the `HypCfg` fields for every item exist since A1. Witness r47b still running (no `[hang]` at ~32 M).
