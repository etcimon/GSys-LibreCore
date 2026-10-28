# Worst five modules after r25 — execution-path analysis and 8-FO4 strategy

Basis: `boards/ai-island/analyze-ai-hyp-r25.{json,ir.json}` on the frozen r20
analyzer (delay-v45 / ir-v6, 8-FO4 budget at 5 GHz / 20 ps). Callers come
from the IR instance table; path classes and node costs from the IR. Nothing
in this document is a landed change or a measured gain; every proposal names
the bench that must gate it. Structural maxima are not STA.

| Module | Max | Over-budget paths | Caller(s) | Children |
|---|---:|---:|---|---|
| `g6lc_ai_desc_engine` | 63.35 | 81 / 137 | `g6lc_ai_island_top.i_engine` | `g6lc_ai_mul_seq` |
| `g6lc_ai_exec` (ai-matrix) | 62.55 | 201 / 302 | `g6lc_ai_coprocessor.i_exec` | `g6lc_ai_acc_bank` |
| `g6lc_ai_policy_subcode` | 62.24 | 39 / 56 | `g6lc_ai_policy_steer.i_subcode` | — |
| `g6lc_ai_policy_codec` | 59.30 | 37 / 85 | `g6lc_ai_policy_steer.i_codec` | — |
| `g6lc_ai_inval_queue` | 52.25 | 8 / 21 | `g6lc_ai_island_top.i_inval_queue` | — |

The "over-budget paths" column is the honest picture: reaching 8 FO4 means
every path, not the maximum. The program's landed patterns (ALGORITHMS-EXPERTS
A20 parallel schedule, A33 relocation tiers, A104 one-hot/masked-OR, A134
prepared facts, A140 explicit arithmetic depth; the r19–r25 ownership,
commit-token and interleaving mechanisms) are applied below per module, with
the implementation impact stated as latency, throughput, interface and
verification cost.

---

## 1. `g6lc_ai_desc_engine` — 63.35

**Execution paths.** (a) `check_len_o` (in→out, 54.8): in `ST_CHK_A/B` the
engine computes `ai_bus_len(ptr, span, BeatBytes)` — 64-bit add, compare and
beat rounding — on the pointer selected by state, then presents it to
`g6lc_ai_addr_check` (`check_req_i/check_addr_i/check_len_i → check_ok_o`,
a combinational probe whose verdict (`check_ok_i`) feeds the engine's
next-state in the same cycle). The whole request → check → verdict → state
loop is one cycle. (b) `span_a/b/c_q` capture (reg→reg bundle, 39.0): the
r7 R4 ST_SPAN products from `g6lc_ai_mul_seq` with the degenerate-case
selects and 64-bit saturating adds. (c) The ST_GEMM issue bundle (32.95).

**Caller contract.** `island_top.i_engine` admits one descriptor at a time;
the address-check leaf is combinational and shared only by the engine.
Extra cycles in the check phases are invisible to the island's throughput
(descriptor latency, not GEMM rate).

**Strategy (A134 prepared facts + A33 T1 relocation across a state).**
1. Compute `len_a_q`, `len_b_q` in ST_SPAN as each span lands
   (`spa_done`/`spb_done` are one cycle before the earliest ST_CHK_A), and
   present registered `check_len_o`/`check_addr_o` per state. This removes
   the 54.8 cone from the in→out path; the remaining probe path is the
   leaf's own compare (`g6lc_ai_addr_check` is at 8.5).
2. Split the probe into request and verdict cycles: register the leaf's
   `check_ok` and consume it in the next state cycle (`ST_CHK_x` → wait one
   cycle). Converts the request/verdict loop into two 1-cycle paths.
3. Spans: the saturating 64-bit sum and the four degenerate selects are an
   exclusive-arm structure — compute the arms in parallel assigns and
   select one-hot (A104); the mul_seq result registers already decouple the
   products. Expect ~39 → ~20.
4. ST_GEMM issue bundle: split per output family (P6) — `gemm_issued_d`,
   `state_d`, `status_d` are billed with the shared condition chain.

**Impact.** +1–2 cycles per descriptor check phase; no interface change at
the island boundary; `addr_check` leaf unchanged. Gate: the desc-island
bench (`run-desc-island.sh` through `run_ai_spine_review.py`) plus the
island DMA smoke. Expected module maximum after 1–4: ~30 (the ST_GEMM and
span bundles), with the probe path at the leaf's 8.5.

---

## 2. `g6lc_ai_exec` (ai-matrix cvxif) — 62.55

**Execution paths.** Three atomic multipliers: `rq_prod = rq_aval_q *
rq_sc_w` (48×48 requantization, 62.55, in the three-phase `ST_RQ` window
`rq_ph_q = 0/1/2`, product registered at phase 2), and the four `dot4`
8×8 signed/unsigned products (56.0 each) feeding the dot tree. The
remaining 198 over-budget paths are the accumulator-bank/requant bundles
(`rq_adj` 31.6, round/negate selects).

**Caller contract.** `g6lc_ai_coprocessor.i_exec` is the CVXIF result path:
multi-cycle instructions with a result handshake; the ISA contract allows
variable latency per instruction class (the RQ sequence is already three
phases).

**Strategy.**
1. RQ product: replace the atomic multiply with the island's sequential
   shift-add multiplier (`g6lc_ai_mul_seq`, 20.0) or a 4-cycle radix-16
   Booth pipeline. The RQ window grows from 3 to ~6 phases for the
   sequential form; the 16-bit scale makes a 16-row shift-add (one row per
   cycle) exact in 16 cycles, or 4 cycles with four rows per cycle (each row
   addition ~12–14 FO4). Choose four-per-cycle: +1 phase, product path ~30.
   (The r24 attempt to narrow the operand type measured 63.55 — the analyzer
   bills the operator width, so only a structural split moves it.)
2. dot4 products: the A140 pattern already landed in `g6lc_ai_pe_dot_pipe`
   (14.8): two-stage partial-product/tree. Reuse that cell for the four
   lanes; the instruction's result latency grows by one cycle.
3. Requant select chain (`rq_adj`, round, negate): compute both polarities
   in parallel (as the r21 FP adder does) and select on the registered
   sign; move the `-rq_t_rnd` negate into the carry-in of the rounding add.
4. Split the accumulator-bank update bundles per output family (P6) and
   register the bank index decode one phase earlier (A134).

**Impact.** +1 cycle on dot4 class, +1 phase on RQ; no change to the CVXIF
interface fields; `acc_bank` unchanged. Gate: the cvxif `tb_g6lc_ai_enq_ready`
/ exec leaves (`run_ai_spine_review.py --enq`) and the core-side ai
instruction tests. Expected maximum after 1–4: ~30 (bank bundles), with 60+
paths still above 8 requiring the P6 family split to finish.

---

## 3. `g6lc_ai_policy_subcode` — 62.24

**Execution paths.** (a) Family-1 candidate terms (62.24 bundle):
`policy_reuse_gain(r, c)` (44.85 — a small division by `rows+cols` inside
the package function), `candidate_ok` (16.4). (b) The three serial
multiplies across SERVICE/TOTAL: `groups_q` (17×17, 52.3), `service_q`
(25×25 + add, 59.3), `cost_q` (28×28, 60.3) — each in its own state but
each over budget as an atomic operator. (c) `choose`/`better` (61.3): a
64-bit sum compare on `winner_cost + constants < base_cost`.

**Caller contract.** `policy_steer.i_subcode` runs the evaluator off the
GEMM path (telemetry/steering); the r17 split already made its result a
published token. Extra evaluator cycles only delay a steering decision.

**Strategy.**
1. `policy_reuse_gain(r, c)`: r and c take 5 values each → a 25-entry
   constant table indexed by `{r, c}` (A104 constant table; the r21 slot-base
   table pattern). 44.85 → a 25:1 select (~6).
2. The three products: all operands are ≤ 17–28 bits and the evaluator is
   sequential — use one shared `g6lc_ai_mul_seq`-style accumulator across
   three extra states (~20 per step), or keep atomic products but split
   each into two registered halves (A140 tiles + one final add). Since
   nothing consumes `cost_q` for ~32 cycles (the evaluation tax), the
   sequential form costs no throughput.
3. `choose`: fold the three constants into one registered `threshold_q =
   base_cost_q - (Switch + Evaluation + MinSavings)` computed once per
   evaluation (saturating), so the per-candidate compare is a single 28-bit
   compare (~12) instead of a 64-bit sum then compare.
4. `candidate_ok`: the mask tests `(m_q & ((1<<r)-1)) == 0` are per-r
   constants — precompute `m_align_ok[r]` for the five r values at job
   capture (A134), select by r.

**Impact.** +3–4 states per candidate (eight candidates per evaluation);
cost outputs unchanged bit-for-bit. Gate: `run_policy_r17.sh` (policy
pipeline bench, 5,568 topology comparisons). Expected maximum: ~20.

---

## 4. `g6lc_ai_policy_codec` — 59.30

**Execution paths.** The accept-cycle feature/encode cone (dense control
cone, 59.3): `policy_bucket(m/n/k)` (9 each, parallel), the sparse-residue
(now 8-bit clear-two-bits), `features.continuous` (compare against
`state_q.shape`), `evaluate = accept && (new_batch || features !=
signature)`, `candidate = evaluate ? policy_encode(features) :
state_q.candidate` (11), then `miss` and the per-family next-state writes.
Second: the warm/prediction publication bundle (29.0) and the f2 decode
stage (18.9).

**Caller contract.** `policy_steer.i_codec` presents one job per `accept`
(valid/ready; the r17 request capture retains the one-cycle pulse). The
codec's `ready_o` already includes a window gate, so a registered feature
stage is legal if `ready_o` drops for the extra cycle or if features are
captured into a one-entry skid.

**Strategy (A134 + A33 T2 one-stage pipeline).**
1. Feature stage: capture `features` into `f1_features_q` on accept (the
   buckets, residue and shape compare run against inputs only), and run
   `evaluate/encode/miss` and the state update one cycle later from the
   registered features. The signature compare then reads two registers.
   `ready_o` must exclude the cycle in which `f1` is occupied unless the
   steer side tolerates back-to-back accepts (it does not need to: jobs
   arrive at GEMM-job rate).
2. `policy_encode`: its priority chain over buckets is an exclusive case;
   express as one-hot class bits ANDed with constant codes (A104) — the
   analyzer bills 11 today; ~5 after.
3. Warm/prediction bundle: P6 per-register processes (`warm_valid`,
   `warm_addr`, `prediction_pending` are billed with a shared condition
   chain at 12.5 each).

**Impact.** +1 cycle from accept to `policy_work_valid`; the r17 publisher
joins codec and topology by job, so the join absorbs the shift (verify its
ordering cases: all three PMU completion/result orders in the bench).
Gate: `run_policy_r17.sh`. Expected maximum: ~25 (encode/miss stage).

---

## 5. `g6lc_ai_inval_queue` — 52.25

**Execution paths.** The AW acceptance path (reg→out, 52.25): `aw_last_byte
= aw_addr + ((len+1) << size) - 1` (20.3) → `aw_line1`, `aw_nlines` (11.7)
→ `tail_same` (8.4, compares against the queue tail entry) → `aw_hold_o =
full && !tail_same` (11.8). `aw_hold_o` gates the island's DMA AW valid
(`island_top` line ~1303: `held_req.aw_valid = ... && !dma_aw_hold`), so
this is a same-cycle backpressure term on the AXI write channel.

**Caller contract.** `island_top.i_inval_queue` observes the DMA master's
AW/B channels to invalidate resident operand lines; the hold exists only
when the queue is full and the new AW does not coalesce into the tail.

**Strategy (the recorded R6 remedy, as a skid rather than a hold).**
1. Replace `aw_hold_o` with a two-entry skid at the queue input: accept AW
   unconditionally when the skid has room (`hold = skid_full`, a registered
   fact), compute `last_byte/nlines/tail_same` from the skid entry one
   cycle later, and coalesce or push from there. The r11 attempt that
   registered the hold itself rose to 53.6 because the hold stayed on the
   cone; a skid removes the arithmetic from the valid path entirely.
2. `aw_last_byte`: `(len+1) << size` with `size` ≤ 3 bits and `len` 8 bits is
   a 4-way constant-shift select plus one add; write it as such (A104) so
   the analyzer does not bill a general shifter — also valid without the
   skid.
3. Line arithmetic: `aw_nlines` only needs the low `8 + LineShift` bits of
   the two line numbers (narrow the subtract).

**Impact.** No change to AXI ordering (the skid is in-order); one cycle of
additional AW latency when the skid is occupied; B-side accounting
(`land_q`, `cnt_q`) must count skid entries as pending. Gate:
`tb_g6lc_ai_inval_queue` (the inval-queue bench) and the island DMA smoke.
Expected maximum: ~15.

---

## Cross-cutting notes toward 8 FO4

- **Everything above is latency-for-depth.** None of the five modules sits
  on the GEMM MAC rate; the costs are descriptor latency, evaluator
  latency, one AW cycle and one CVXIF result cycle. That is the right
  trade for a 5 GHz nameplate and matches the program's accepted r19–r23
  trades.
- **Function calls are billed as callee makespans.** The remaining large
  nodes are package functions (`ai_bus_len`, `policy_reuse_gain`,
  `policy_encode`, `policy_bucket`); constant tables and inline one-hot
  forms are the productive rewrite, as the slot-base table and the sparse
  residue showed (85.8 → 59.3 from one such identity).
- **Atomic multipliers do not respond to operand casts** (exec r24
  countercase); only tiling (A140, as `pe_dot_pipe`) or sequential
  accumulation (`g6lc_ai_mul_seq`) moves them.
- **Counting, not maxima.** After the maxima above fall to ~15–30, the
  per-module over-budget counts (81, 201, 39, 37, 8) decide the remaining
  work: each needs the P6 per-family split of its state-update bundles and
  prepared-fact registers for every compare that reads a job constant.
  That is mechanical but wide; the GEMM sequencer took four passes for the
  same shape of work.
- **Measurement caveats carry over:** module maxima on a frozen analyzer,
  cross-module sums not validated as connected cones (r19 audit), no STA,
  generic lint/synth blocked by the hyp config lookup.

Suggested order by value per verification cost: subcode (1,3,4 — bench in
hand), inval_queue (2,3 — bench in hand, then the skid), codec (1,2),
desc_engine (1,2 — needs the desc-island bench), exec (needs the cvxif
leaf and core-side tests).
