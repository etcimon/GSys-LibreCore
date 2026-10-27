# r78 worklog

## Item 1 — witness hyp8-osbi-scalar-r47b (alive)

16 stall-census prints (~32M cycles), UART bytes + l1-wbuffer drop
traffic flowing continuously, no [hang] blocks, no exit/tohost line
yet — the sim is still running detached (pid 1952306). [equiv]
counters are final-only; nothing to collect. Milestones so far are
progress-only (no sbi_*/kernel-console line appeared in the tail).
Collect: testharness_proxy.py pull --tag hyp8-osbi-scalar-r47b.

## Item 2 — g6lc_rename_recover gen_pub_v :412-417: NULL, REVERTED

Census (ir_hot_nodes r77-census.ir.json, module top-25): the deep
nodes are rsvd_mask[pub_ck_slot_i[p]] L339 (13.1), the
ckpt_fmap_q/ckpt_map_q checkpoint writes L704-705 (13.1), and the
per-hart-flush arch_ref walk L589-594 (11.0, 25 LHS). The pub_v
select itself billed 9.0. t1_wr_s is already a one-hot slot-hit OR
of pub_ck_oh (per-port decoded one-hot, prepared at the producer —
the A120 producer-side decode the brief asks for already exists);
t1_live_s is a registered-state ring-offset compare per slot;
t1_aval/t1_mk/t1_faval/t1_fmk are masked-OR columns already.

Applied anyway per brief: the 3-way select as masked-OR of two
parallel terms ({W{wr}}&aval | {W{~wr}}&(q | (mk & {W{live}}))) +
pub_hart_v 2-term; serial ref under translate_off + r78_pubv_eq +
counter; mutant G6LC_MUT_RNREC_PUBV drops the live qualifier.
Lint clean. Board analyze-r78-rr.json: module row UNCHANGED at
31.8 FO4 (rr 31.8 pres 31.2) — the limiter moved AGAIN, from :412
to :641 = the per-hart-flush `arch_ref[amap_d[h][a]]` walk +
`owner_d[i]==h && !arch_ref[i]` scan over PRF_ENTRIES, a THIRD
pre-existing co-limiter at the same depth. NULL -> reverted
byte-exact (restored sha c273cd24041f4f0b).

Co-limiter chain summary for a future pass: :589/:641 flush
arch_ref walk, :339 rsvd_mask dynamic write, :412 gen_pub_v mux,
:704-705 ckpt payload writes — all ~31.8; the module needs its own
bundle partition inside the flush arms or a staged arch_ref.

## Item 3 — load_unit state_d arm census + moves

Arm table (census ir_hot_nodes + the 37-arm exclusive-case note;
"terms read" from the case text; every term is a 1-bit predicate —
NO arm reads the 56-bit load_pa_now/pa_out_lo select directly):
  arm ~line  FO4   terms read (all 1-bit)
  L1053      15.3  WPO->WAIT_PAGE_OFFSET: fwd_final (15.0,
                   st_fwd_covers&ld_checked_head — already shared),
                   data_rvalid, st_pipeline_busy, lu_replay_fire
  L1056      15.3  ->WAIT_GNT: same head terms + data_gnt, dtlb_hit_i,
                   stall_ni, paddr_ni
  L1048-50   14.3  ->IDLE + pop_ld_o + lu_replay_o: fwd_complete guard
                   (page_offset_matches_i && fwd_final && !rvalid)
  L992-1010  12.5  IDLE accept_req arm: spec_ld, paddr_ni, stall_ni,
                   st_pipeline_busy, wpo_block guard, data_gnt,
                   dtlb_hit_i
  L1121-1139 12.5  same arm second copy (accept_req re-entry)
  L1194-1198 11.9- SEND_TAG drain arms: data_rvalid, pop_ld_o
              12.9
  The two "deep" feeders into the FSM are stall_ni 22.6
  (paddr_ni region-check on dtlb_ppn_i<<12 + inflight_stores +
  not_commit_time — all already single-shared wires) and fwd_final
  15.0 (already shared by F15b + these arms). No 56-bit term sits
  in any state arm's cone — the item-6a check is CLOSED.
Exact move found + applied: A135 share of the two duplicated FSM
guards (fwd_complete = page_offset_matches_i && fwd_final && !rvalid;
wpo_block = !page_offset_matches_i && !(covers && !ld_checked_head))
computed 2x in state_d and 2x in the rf_ mirror -> one wire each,
8 sites total. Board analyze-r78-lua.json: NULL — module row
unchanged 37.2/33.5 (limiter is into-L5 window 0, not the FSM).
Reverted byte-exact (the share is harmless but the rule is strict).
Verdict for the rank-1 design: the FSM's deepest input is the
paddr_ni region check feeding stall_ni — a registered "NI verdict"
(r75 S3 two-edge style) is the only remaining move and it is rank-1.

## Items 3–5 (second handoff)

Item 3 load_unit state_d census — arm table recorded above; the only
exact share (fwd_complete/wpo_block, 8 sites incl. the rf_ mirror)
boarded NULL at analyze-r78-lua.json (37.2/33.5 unchanged — limiter
is into-L5 window 0, not the FSM) → reverted. Item-6a CLOSED: no
state arm reads the 56-bit pa select.

Item 4 iq_bank/iq_arb:
  4a one_older[e] N^2 only[] mask -> ENTRIES parallel equality
    compares (single-hot table, still no subtract). Board
    analyze-r78-iqba.json: 32.3 -> 30.1 in-stage SEL. KEPT.
    Dispatch leaf: HYP8_DISPATCH_PASS checked=125, r69 steer eq
    silent.
  4b cterm fu/lat/cls decodes stored at allocation (iqb_entry_t
    +5 fields decoded once at newrec) — implemented then boarded
    NULL at analyze-r78-iqbb.json (30.1 unchanged) and reverted
    (~416 flops for no gain).
  4c iq_arb :826 reg->out: cone = win_s(registered) -> take_grant
    (!pres_q.v && take_ok && !take_kill) -> bank decode -> take_*.
    The dynamic-index writes are already one-hot decodes of the
    same registered index; the depth lives in take_ok/take_kill
    upstream — no justified exact rank-0 move. Recorded.

Item 5 g6lc_tlb flush arms — A135 per-entry hoist of the shared
VMID/ASID match terms (tl_vmid_ok/tl_asid_ok in the VVMA arm, 4x+2x
sites; tl_gvmid_ok in the GVMA arm, 2x). Pure sharing, no ref block
(same expression, named — consistent with earlier A135 hoists).
Board analyze-r78-tlb.json: 30.9 -> 24.9 (limiter moved :634->:281).
KEPT.

## r78 batch end

hyp8-integration-r78: rc=0, sha 6cc9cc8cb7ad30c2080d0449518a7ccd54bce398e009ed15661dabb5b6c89f35, lint 0/0.
hyp8-r78-smokes: results above.
analyze-r78-all.json: structural clock 1.08 GHz (37.2 FO4
load_unit — unchanged; limiter still into-L5 window 0).
Diff vs r77-all: g6lc_iq_bank 32.3->30.1 (-2.1); g6lc_tlb
30.9->24.9 (dropped out of the top-20).
Kept RTL this pass: g6lc_iq_bank one_older table, g6lc_tlb flush
shared-term hoist.
