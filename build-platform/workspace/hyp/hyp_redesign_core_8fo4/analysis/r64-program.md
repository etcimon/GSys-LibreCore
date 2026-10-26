# r64 program — from the equivalent-rewrite floor toward < 20 FO4 structural

Board of record: `boards/hyp8-core/analyze-r63.json` (argv in `analyze-r63.cmd`, r44 map
75d16bc9). Method: sv-timing carry-over census per module (path kind, class note,
chain, stage window) → classify the limiter → choose the transformation class →
measure → accept only on a module drop with no other rise → record countercases.

## 1. Where the equivalent rewrites stopped (r52–r63)

| class | modules | state |
|---|---|---|
| dependency-floor hoist (B1) | ptw 35.7→27.4, dcache_ctrl 28.6→24.0, fe_override 30.3→24.9, iq_arb 33.9→30.6, sb_commit 27.4→25.4, sb_lifecycle 25.9→24.9 | done; further hoists measure null (rename_recover) |
| real cone rewrite | lsq_reduce 29.9→15.1 (age matrix), dcache_mem 33.3→28.4 (T1 snapshot / T2 tree), tlb prefix removal 31.0→30.85 | done |
| countercases | iq_bank ge1/ge2 (42.5), alu split (48.1), iq_arb bank decode (34.2), tlb per-row tags_n (48.6), load_unit hoist/split (null) | recorded |

Remaining active board ≥ 20 (r63): load_unit 41.0 (bundle; plain 35.05), iq_bank 32.3,
rename_recover 31.8, tlb 30.9, iq_arb 30.6, store_unit 26.7, loop_buffer 26.9, aes 26.0,
IRO 28.0, alu 27.9, ptw 27.4, dcache_mem 28.4, sb_commit 25.4, sb_lifecycle 24.9, dispatch
25.3, lsq_event 25.1, controller 25.1, wbuffer 24.9, dcache_ctrl 24.0, rob 24.4, … (full
list in `timing-summary.json`). Everything left is either an analyzer floor (bundle/dense
makespan with max_field ≤ 15) or a real same-cycle cone whose contract forbids an
equivalent cut. Reaching < 20 therefore needs **latency-changing transformations**: new
stage windows, decoupled queues, or caller-specialized functional splits. Each one
changes a caller contract and must be paired with a config knob, a legality assert, the
latency tables, and a leaf.

## 2. Stage-split designs (lead, design level; implement one at a time)

### S1 load_unit publish port — dedicated exception completion lane (41.0 → ≤ 25 est.)
Limiter: the shared `valid_o/trans_id_o/ex_o/result_o` port arbitrates data publication,
the r51 pending-exception FIFO, and the FSM. Design: a second completion lane
`ex_valid_o/ex_trans_id_o/ex_o` consumed by the scoreboard/ROB as an exception-only
writeback (no data). The scoreboard already accepts N WB ports (`NrWbPorts`); add one
port whose `we` is never asserted and whose `ex.valid` is always 1 when valid. Load data
publication then never competes with exceptions: `pub_any` loses its `ex_pend` arms, the
FIFO publishes on its own lane. Contract changes: `NrWbPorts+1` in the hyp8 config,
`WbReserve`/`WbLanes` bookkeeping (the lane is exception-only so it needs no reservation),
rvfi probes see an extra port, commit_stage exception merge reads from either lane
(exceptions already pair by trans_id). Verify: memory leaf (keep L1–L4 + mutant), issue
leaf (WB port count), smokes, witness. Timing expectation: load_unit plain path drops the
`ex_pend_sel`/`pend_state_ok` terms; the bundle makespan loses 6 LHS.

### S2 IQ select → payload stage (`IqSelStages`, 32.3 → ≤ 22 est., +1 issue latency)
Limiter: `ready → ort → cand0/cand1 → cterm gather → out0` in one cycle. Design: register
`cand0_oh/cand1_oh` (and the `ready` snapshot used for the kill check) at a new SEL/PAY
edge; the payload gather and the xbar run from the registered one-hot. The wakeup
countdown tables (`ooo_flu_cycles`) gain +1 for every class exactly as `IqArbStages` did
in r43-T; `g6lc_iq_legal`'s registered `at_head` compare stays. The sticky-kill sweep of
r47 must cover the new edge (a candidate cancelled between SEL and PAY is squashed, not
taken). Config legality: `IqSelStages inside {0,1}`; speculative wakeup stays off with
`WbReserve`. Verify: issue leaf k-offset sweep extended by one, mutant without the sweep
fails by name; smokes will change cycle counts (report), instruction counts must not.

### S3 rename_recover (31.8, bundle floor) — recovery as a two-edge window
Limiter: 26 next-state fields whose makespan is the analyzer floor; the real content is a
same-edge pulse+index restore of the RAT from a checkpoint. Design: split the restore into
“select checkpoint / compute masks” (edge 1) and “write RAT rows” (edge 2) — the frontend
is already stalled during recovery (`flush`), so +1 recovery cycle costs only mispredict
penalty. Legality: `RenameRecoverStages inside {1,2}`; the issue barrier must hold the
rename port for the extra cycle. Verify: rename leaf (`run_ooo_rename_prove/cover`), the
`hyp8_raw_window.S` mini, smokes.

### S4 TLB lookup (30.9) — context pre-match register
Limiter: `tags_q→lu_hit` compare (vpn levels + asid/vmid/hart/stage) then the response
gather. Design: a per-entry registered `ctx_match_q` (asid/vmid/hart/stage/global) computed
from `tags_d` and the live context inputs each cycle; the lookup ANDs only the vpn compare
with the register. The one-cycle staleness after an `asid_i/vmid_i` change is covered by
the satp-write flush (≥ 2 cycles before the next translation); add an assert that no
lookup is valid in the cycle after a context change, or force a miss there (safe: a miss
only costs a PTW). Verify: TLB matrix leaf + the in-DUT old-form miter.

### S5 store_unit (26.7) / loop_buffer (26.9) / aes (26.0) / alu (27.9)
- store_unit: `WAIT_STORE_READY`/translation handshake → split address formation from the
  post (`LsuAguStages` already exists: measure `=2`).
- loop_buffer: window compare on the maintained sequential PC is at its floor; the
  remaining cone is the fetch-window select — accept or move the select into the FTQ edge.
- aes: pipeline the round (FU latency class +1 via `FpuLatOverride`-style knob) — unused by
  boot, lowest priority.
- alu: shifter dense cone is real; a 2-stage shifter needs `AluStages=3` (exists) — measure
  the board at `AluStages=3` before touching the RTL.

### S6 excluded arms (user request: include them)
shared_tlb L579 (51.2 bundle, hoist), ptw_leg_decode L174 (53.0, B1 hoist of the PDEC=0
arm), slice_dispatch L202 (29.9, hoist). Lint under closure-only configs
(`UseSharedTlb=1`, `PtwDecodeStage=0`, `SliceOoOEn=1`); numbers tracked on
`analyze-r6x-all.json` (no exclusions); they stay excluded from the active clock board.

## 3. Order and gating
S6 (cheap) → S1 (removes the clock-setter) → S2 → S4 → S3 → S5. Each item: census,
design note, implementation, board, leaf + mutant, lint ×3, smokes, log, and — because
every S item except S6 changes latency — one OpenSBI witness per landed item.
