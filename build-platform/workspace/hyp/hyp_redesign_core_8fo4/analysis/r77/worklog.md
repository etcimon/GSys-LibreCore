# r77 worklog

## 0. Witness r47b (alive)

8 stall-census prints (~16M cycles), l1 wbuffer drop lines flowing,
no [hang]; still running detached (pid 1952306). Collect:
testharness_proxy.py pull --tag hyp8-osbi-scalar-r47b

## 1. g6lc_iq steer — KEPT (101.7 -> 37.3 pres)

core/ooo/g6lc_iq.sv steer block (was L212-237 serial usedc scan):
rewritten per output family — ge[k][b] = (bank_free[b] >= k)
continuous compares (k=1..NP, early preparation off the registered
bank_free); per-lane p genvar block: nused = popcount of earlier
lanes' pick_oh at each bank (small per-bank always_comb), elig[b] =
ge[nused+1][b], rotr/x&-x/rotl pick unchanged, steer_found[p] =
disp_valid_i[p] & |pick, asgn[p] masked-OR of bank_idx_c;
group_fits = &(~disp_valid_i | steer_found) (was fits='1 then
cleared inside the valid gate — same value). Parametric in NP;
assert (NP <= BANKS) added beside the power-of-two check.
g6lc_r69_steer_eq reference untouched (compares group_fits + asgn
when fits) — must pass in the next sim gate.
Board analyze-r77-iq.json: pres 37.3 vs census 101.7 (-64.4); rr/inst
0.0 (no registers in the module — its whole cone is pres). KEEP.
Lint: 0 new diagnostics (same 16 pre-existing fetch_dbg IMPLICIT).
Pre-zip: analysis/r77/pre/g6lc_iq.sv.zip.

## NOT DONE (session budget)

- Item 2 load_unit cones (NI late-select, slot_cancel_live share,
  state-arm read-path) — not started.
- Item 3 g6lc_rename_recover p_next_state split — not started.
- Batch end: closure/integration/smokes/analyze-r77-all not run;
  the steer edit is lint-clean but not yet sim-verified (the
  r69_steer_eq gate and the dispatch leaf/smokes are pending — run
  before adopting in any integration build).

## r77 handoff-2 progress

- Lead fix to the steer nused (nused += pick_oh[j][b] &
  disp_valid_i[j] — the serial form skipped invalid lanes; a dead
  lane-0 + live lane-1 group would have been refused and fired
  r69_steer_eq): verified in place at g6lc_iq.sv:238.
- Re-lint: clean (16 pre-existing fetch_dbg only).
- Board analyze-r77-iq2.json: pres 38.3 (+1.0 for the dead-lane term;
  vs 101.7 census). KEEP stands.
- PENDING: the dispatch-leaf eq run (HYP8_DISPATCH_PASS, needs the
  remote leaf path — local runner covers memory only). The steer
  edit remains sim-unverified until that gate runs; do not adopt in
  an integration build without it.
- Items 2 (load_unit cones), 3 (rename_recover split), 4 (batch end):
  not started — budget.

## Step 1 gate — dispatch leaf on the steer rewrite (lead, local WSL Verilator 5.020)
- Runner `analysis/r77/run_hyp8_dispatch_local.sh` (full `Flist.g6lc_hyp8` + `tb_g6lc_hyp8_control.sv`, top `tb_g6lc_hyp8_dispatch`, `-Wno-BLKANDNBLK` for the stock-5.020 cvfpu limitation).
- `HYP8_DISPATCH_PASS checked=125 pop_take_same=0 opasm_int=1 opasm_fp=1`; with `+equiv_report`: `[equiv] g6lc_iq r69 steer: checked=619`, zero `equiv steer` errors. The steer rewrite (with the dead-lane `disp_valid_i[j]` term) is sim-gated; adoption in the next integration build is authorized.

## Item 2 — load_unit

(a) NI late-select: DOCUMENTED COUNTERCASE / false premise, not
implemented. paddr_ni (load_unit.sv:822) is computed on the
page-aligned source `{{52-PPNW{0}}, dtlb_ppn_i, 12'd0}` — NOT on the
56-bit load_pa_now/pa_out_lo select (the census note "PMA check on
the live 56-bit pa select" does not match the RTL). The three
select sources are not NI-equivalent — lsu_ctrl_i.vaddr is VIRTUAL
(a different page), so is_ni(source) selected by the same key would
give wrong answers for the vaddr source; an exact late-select form
does not exist here. The file already carries the same lesson:
r42-T R7a countercase comment at :813-820 — two "1-bit verdict +
validity bit" reformulations measured WORSE (57.9/57.1 FO4) and were
reverted. No mutant, no ref block: there is nothing to be exact
against. Left unchanged.

(b) slot_cancel_live[NLD] shared vector: LANDED at :499-505.
old_hit (gen_ldbuf_flush), ex_pub (:1418) and the miss_replay scan
(:1564) now read slot_cancel_live[...] instead of
cancelled_mask_i[ldbuf_q[...].trans_id] — two-level dynamic index
removed from each consumer (A135 row-local). Exact (identical
function). Local lint: clean (16 pre-existing fetch_dbg only).
Board + leaf not run this session (budget); the edit is a pure
sharing so the keep gate is module-row-only.

## load_unit 2(a)/(b) — lead verdicts
- 2(a) NI late-select: brief premise wrong (paddr_ni is evaluated on the page-aligned `{dtlb_ppn_i,12'd0}`, not on the pa select; the r42-T R7a countercase at :813–820 already covers the 1-bit-verdict reformulations at 57.9/57.1). Not implementable as an exact late-select; closed.
- 2(b) `slot_cancel_live` share: board `analyze-r77-lu.json` = 37.2/33.5/19.2/37.2 — NULL (the analyzer already shared the row); leaf PASS 160. Reverted byte-exact to `analysis/r77/pre/load_unit.sv.zip` per the keep-only-on-drop rule (no unmeasured churn).
- load_unit's remaining levers are therefore rank 1: item 6a (state_d from validity bits) needs a measured census of which arm reads which 56-bit term — deferred to the next pass with the census as the first step.

## Item 3 — g6lc_rename_recover p_next_state split: NULL, REVERTED

Split attempted (4 families: p_amap/p_ckpt/p_map/p_free, skeleton
replicated verbatim, locals rel2/adv_h in p_ckpt + squashed/arch_ref/
free_rep in p_free, n_ret kept at module level after a latch-warn
round on the automatic-array form). Lint clean after the fix (16
baseline). Board analyze-r77-rr.json: module row UNCHANGED at 31.8
FO4 (rr 31.8, pres 31.2->27.7) — the limiter moved from :589 (the
bundle) to :412 (the gen_pub_v per-slot t1_wr/t1_live mux gather),
a pre-existing co-limiter at the same depth. Removing the bundle
exposes the gather; module FO4 does not drop. Per the keep rule:
reverted byte-exact from analysis/r77/pre/g6lc_rename_recover.sv.zip.
The .svfrag with the split text is preserved in r77/pre/ for
reference. p_t1_rnrec_eq never ran — no leaf needed once the board
said NULL.

## r77 close

hyp8-integration-r77: rc=0, 346s; model sha
56d3601d24ec2269bb62eeeb887dadf209d3ece4545afea37db74a9bfaac4ea0;
lint scalar/smt2 rc=0 0 %Error.
hyp8-r77-smokes: 7/7 PASS — 685/1011/492/2364/2199/1231/671,
cycle-identical to r76f (the steer rewrite is exact; the r69 eq
gate also passed the local dispatch leaf: checked=619).

Batch-end board boards/hyp8-core/analyze-r77-all.json (+.cmd):
structural clock = 1.08 GHz (37.2 FO4, load_unit, into L5 window 0)
— unchanged from r76-all (load_unit was already the limiter; the
steer sits below it).
Module diff vs r76-all: no FO4-column changes (g6lc_iq is
registerless; its improvement is a presentation/stitch change):
  g6lc_iq        pres 101.7 -> 38.3 (iq2 board, dead-lane fix kept)
  g6lc_ooo_dispatch.i_iq stitch 125.2 -> 54.9 (was the #1
    cross-module path in r76-all; now out of the top 5)
Files changed in r77 (all hyp core tree):
  core/ooo/g6lc_iq.sv — per-lane steer rewrite + ge[k] compares +
    NP<=BANKS assert (KEPT; +1.0 FO4 for the lead's dead-lane term).
  analysis/r77/run_hyp8_dispatch_local.sh — local dispatch leaf
    (lead-added; HYP8_DISPATCH_PASS checked=125, eq checked=619).
  analysis/r77/{worklog.md, pre/*.zip, pre/p_next_state_split.svfrag}.
Countercases / nulls:
  load_unit 2(a) NI late-select — false premise (paddr_ni reads the
    page-aligned PPN base, not the 56-bit select; R7a already
    countercased the same idea); not implemented. CLOSED by lead.
  load_unit 2(b) slot_cancel_live — landed then measured NULL on
    analyze-r77-lu.json (37.2 unchanged); lead reverted byte-exact.
  g6lc_rename_recover p_next_state 4-family split — NULL on
    analyze-r77-rr.json: module row unchanged 31.8 FO4; limiter
    moved from :589 (bundle) to :412 (gen_pub_v per-slot mux — a
    pre-existing co-limiter at the same depth). Reverted byte-exact.
Witness hyp8-osbi-scalar-r47b: 14 stall-census prints (~28M cycles,
~7.7M retires cum at IPC ~0.27), UART + wbuffer traffic, no [hang];
still running detached pid 1952306.
