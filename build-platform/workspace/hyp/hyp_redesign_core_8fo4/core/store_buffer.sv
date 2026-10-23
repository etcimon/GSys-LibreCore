// hyp8 provenance: REWRITTEN (sv-timing emit at the 8-FO4 budget)
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 25.04.2017
// Description: Store queue persists store requests and pushes them to memory
//              if they are no longer speculative
// Modified by: Etienne Cimon (comb defaults; Verilator LATCH)
// hyp8: staged around the A141 stationary-slot queue:
//   stb_insert  — S1 capture (lowest-free + age row) / S2 queue writeback;
//                 ready_o is a same-cycle reserved-capacity credit that
//                 charges the staged record and the current arrival (a
//                 registered ready alone was unsound: two owners could
//                 claim the last free slot).
//   stb_commit  — program-order head select + head-match gate + the
//                 one-cycle spec->commit pend (committed stores survive flush).
//   stb_drain   — the emit store_if kernel verbatim (program-order WT drain).
//   stb_fwd     — F1 match / F2 youngest-writer select / F3 data response,
//                 driven by fwd_req_i; the legacy same-cycle st_fwd_* outputs
//                 present the last completed F3 response when
//                 HypCfg.StoreFwdCycles == 3 (+3, recorded decision).

module store_buffer
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg    = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg    = g6lc_hyp_pkg::Hyp8,
    parameter type                   dcache_req_i_t = logic,
    parameter type                   dcache_req_o_t = logic,
    parameter type                   cbo_t          = logic
) (
    input logic clk_i,  // Clock
    input logic rst_ni,  // Asynchronous reset active low
    input logic flush_i,  // full flush: drop all speculative stores
    // FSE S4: younger-only cancel (SB cancelled TIDs); does not touch commit queue
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    // Scoreboard issued mask: an OoO speculative entry is a reservation whose
    // scoreboard slot must still be live (assertion only)
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] sb_live_i,
    input logic stall_st_pending_i,  // Stall issuing non-speculative request
    output logic         no_st_pending_o, // non-speculative queue is empty (e.g.: everything is committed to the memory hierarchy)
    output logic         store_buffer_empty_o, // there is no store pending in neither the speculative unit or the non-speculative queue

    input  logic [11:0]  page_offset_i,         // load VA/PA[11:0] (always available)
    // R3a: full load paddr when DTLB has translated; required for exact STQ match.
    input  logic [G6LCCfg.PLEN-1:0] load_paddr_i,
    input  logic                    load_paddr_valid_i,
    // U5.4 OoO program-order keys. A store may only be observed by a load that
    // follows it in program order, and stores must reach memory in that order.
    // Index order is not age once scoreboard slots are reused, so age is the
    // circular trans_id distance from the oldest live instruction. Both inputs
    // are inert when OoOEn is 0.
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] load_trans_id_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] commit_trans_id_i,
    // T6b-4b: the scoreboard reclaim pointer — the oldest live slot. This is
    // the program-age anchor for the speculative queue's circular ordering;
    // commit_trans_id_i stays the *committing* tid (port-0 slot) for the
    // head-match gate below. Aliases commit_trans_id_i under legacy order.
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] oldest_live_tid_i,
    // N1d: the commit head is an unpublished load (phys_pending — it needs
    // this LSU to make progress). A speculative-queue stall can only clear
    // through commit, so holding a younger load on it is a circular wait;
    // release it and let the LSQ phys_replay scan arbitrate any true alias
    // when the released load publishes its physical address. Constant 0
    // unless the OoO physical-tracking policy (COH_OOO) is live.
    input  logic                          head_phys_pending_i,
    // T6b: hart of the querying load. Under OoO multi-hart a load forwards
    // only from its OWN hart's speculative stores; a peer hart's store is not
    // visible until commit. Constant-0 otherwise (single hart / in-order).
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] load_hart_i,
    // R3a cont.13: D$ write buffer empty — sticky [11:0] match must outlive
    // STQ→wbuffer handoff so post-return loads of *nextoffset see the store.
    input  logic                    dcache_wbuffer_empty_i,
    output logic         page_offset_matches_o, // hazard: stall load until STQ drains / forward
    // T33: the live match comes from the SPECULATIVE queue only (no committed
    // entry, no sticky drain window). Such a store can only leave after every
    // older instruction retires, so a load parked on it in WAIT_PAGE_OFFSET
    // must not hold the load unit against an older load -- the load unit
    // replays it instead (see load_unit.sv).
    output logic         page_offset_spec_only_o,
    // R3a: store→load data forward (byte-merge, oldest→youngest). hyp8: with
    // StoreFwdCycles==3 these carry the last completed F3 response (+3);
    // with ==1 the legacy combinational merge below drives them.
    output logic                              st_fwd_valid_o,
    output logic [G6LCCfg.XLEN-1:0]           st_fwd_data_o,
    output logic [(G6LCCfg.XLEN/8)-1:0]       st_fwd_be_o,

    // hyp8: staged forward request/response (the F1-F3 pipeline)
    input struct packed {
      logic                                        valid;
      logic [G6LCCfg.PLEN-1:0]                     pa;
      logic [1:0]                                  size;
      logic [G6LCCfg.TRANS_ID_BITS-1:0]            tid;
      logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] hart;
      logic [(G6LCCfg.NrLoadBufEntries > 1 ? $clog2(G6LCCfg.NrLoadBufEntries) : 1)-1:0] tag;
    } fwd_req_i,
    output struct packed {
      logic                                        valid;
      logic [G6LCCfg.XLEN-1:0]                     data;
      logic [(G6LCCfg.XLEN/8)-1:0]                 be;
      logic                                        forward_possible;
      logic [(G6LCCfg.NrLoadBufEntries > 1 ? $clog2(G6LCCfg.NrLoadBufEntries) : 1)-1:0] tag;
    } fwd_rsp_o,

    input logic commit_i,  // commit the instruction which was placed there most recently
    output logic commit_ready_o,  // commit queue ready AND (OoO) the committing
                                 // tid is installed in the speculative queue —
                                 // a staged S1/S2 arrival is not yet committable
    output logic ready_o,  // the store queue is ready to accept a new request
                           // it is only ready if it can unconditionally commit the instruction, e.g.:
                           // the commit buffer needs to be empty
    input logic valid_i,  // this is a valid store
    input  logic         valid_without_flush_i, // just tell if the address is valid which we are current putting and do not take any further action

    input  logic [G6LCCfg.PLEN-1:0]  paddr_i,         // physical address of store which needs to be placed in the queue
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id_i, // scoreboard tid (FSE S4 younger cancel)
    // T6b: hart of the arriving store, recorded on its speculative entry.
    input  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] st_hart_i,
    output logic [G6LCCfg.PLEN-1:0] rvfi_mem_paddr_o,
    input logic [G6LCCfg.XLEN-1:0] data_i,  // data which is placed in the queue
    input logic [(G6LCCfg.XLEN/8)-1:0] be_i,  // byte enable in
    input logic [1:0] data_size_i,  // type of request we are making (e.g.: bytes to write)
    input cbo_t cbo_op_i,  // type of cache block operation

    // D$ interface
    input  dcache_req_o_t req_port_i,
    output dcache_req_i_t req_port_o
);

  // FSE S1: speculative/commit queue depths.
  // DeepSpecEn=0 → legacy g6lc_core_pkg::DEPTH_SPEC/COMMIT (4) for netlist identity.
  // DeepSpecEn=1 → next power-of-two of MaxOutstandingStores (capped 16).
  function automatic int unsigned fse_next_pow2(input int unsigned n);
    if (n <= 1) return 1;
    if (n <= 2) return 2;
    if (n <= 4) return 4;
    if (n <= 8) return 8;
    if (n <= 16) return 16;
    return 32;
  endfunction
  localparam int unsigned DEPTH_SPEC = G6LCCfg.DeepSpecEn
      ? fse_next_pow2(
            (G6LCCfg.MaxOutstandingStores < 4) ? 4 :
            (G6LCCfg.MaxOutstandingStores > 16) ? 16 : G6LCCfg.MaxOutstandingStores)
      : int'(g6lc_core_pkg::DEPTH_SPEC);
  localparam int unsigned DEPTH_COMMIT = G6LCCfg.DeepSpecEn
      ? fse_next_pow2(
            (G6LCCfg.MaxOutstandingStores < 4) ? 4 :
            (G6LCCfg.MaxOutstandingStores > 8) ? 8 : G6LCCfg.MaxOutstandingStores)
      : int'(g6lc_core_pkg::DEPTH_COMMIT);

  // U7c cbo.zero commit-drain expansion (Zicboz): the store unit posts ONE
  // speculative entry carrying cbo_op=CBO_ZERO, the line-aligned base
  // address, zero data and a full byte enable. On commit the drain below
  // issues CBOZ_BEATS consecutive full-width stores at base + beat*stride —
  // each beat is tagged CBO_ZERO so the WT write buffer forwards it as an
  // ordinary store and returns the one-shot rvalid this protocol needs
  // (HPDCACHE answers every store via need_rsp). One instruction -> one
  // speculative entry -> one commit entry -> one commit; only the memory
  // drain is multi-beat, so queue accounting and the scoreboard's single
  // completion stay 1:1 and no entry can be orphaned.
  // T44: the block is the architected CBO block (config_pkg::CBO_BLOCK_BYTES,
  // the .dts cboz-block-size = 64), not the D$ line. DCACHE_LINE_WIDTH is in
  // bits (128 on the OoO packages), so the previous `DCACHE_LINE_WIDTH / 8`
  // drained two 8-byte beats and left bytes 16..63 of every block stale:
  // Linux's clear_page (back-to-back cbo.zero) handed out page tables and
  // user pages with old content — move_page_tables read a kernel pointer
  // as a PTE on server1 L1, init segfaulted on a 0xcc.. pointer on the
  // 2-hart server1. Must match store_unit's alignment (same constant).
`ifdef G6LC_MUT_CBOZ_LINE_BYTES
  localparam int unsigned CBOZ_LINE_B =
      (G6LCCfg.DCACHE_LINE_WIDTH >= 64) ? (G6LCCfg.DCACHE_LINE_WIDTH / 8) : 64;
`else
  localparam int unsigned CBOZ_LINE_B = config_pkg::CBO_BLOCK_BYTES;
`endif
  localparam int unsigned CBOZ_STRIDE = G6LCCfg.XLEN / 8;
  localparam int unsigned CBOZ_BEATS =
      (CBOZ_LINE_B / CBOZ_STRIDE) > 0 ? (CBOZ_LINE_B / CBOZ_STRIDE) : 1;
  localparam int unsigned CBOZ_BEAT_W = (CBOZ_BEATS <= 1) ? 1 : $clog2(CBOZ_BEATS);
  // Line-offset width: also the granularity of the [11:0] hazard match below
  // (a cbo.zero line can never cross a 4 KiB page for any sane line size).
  localparam int unsigned CBOZ_OFF_W = $clog2(CBOZ_LINE_B);

  logic [CBOZ_BEAT_W-1:0] cboz_beat_q, cboz_beat_n;

  localparam int unsigned HID_W = $clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2);
  // T6b: speculative forwarding is same-hart only when two OoO harts can be
  // resident. The committed queue is NOT filtered — a committed store is
  // architectural and visible to every hart.
`ifdef G6LC_MUT_STB_NO_HART
  // Review-only mutation: speculative forwarding ignores the hart tag — a
  // peer hart's in-flight store can feed this hart's loads.
  localparam bit HART_OWN = 1'b0;
`else
  localparam bit HART_OWN = G6LCCfg.OoOEn && G6LCCfg.NrHarts > 1;
`endif

`ifdef G6LC_MUT_STB_NO_HEAD_GATE
  // Review-only mutation: drop the head-blocked liveness release — a
  // phys-pending commit head no longer frees the speculative stall, so the
  // N1d circular wait re-forms.
  localparam bit HEAD_GATE_EN = 1'b0;
`else
  localparam bit HEAD_GATE_EN = 1'b1;
`endif

  // the store queue has two parts:
  // 1. Speculative queue
  // 2. Commit queue which is non-speculative, e.g.: the store will definitely happen.
  typedef struct packed {
    logic [G6LCCfg.PLEN-1:0] address;
    logic [G6LCCfg.XLEN-1:0] data;
    logic [(G6LCCfg.XLEN/8)-1:0] be;
    logic [1:0] data_size;
    cbo_t cbo_op;
    logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id;  // FSE S4: for younger-only cancel
    logic [HID_W-1:0] hart;  // T6b: owning hart (speculative queue only)
    logic valid;  // this entry is valid, we need this for checking if the address offset matches
    logic wait_rvalid;  // need to wait for rvalid...
    // G1ah: this spec entry already forwarded to a load. SMT+SS flush/cancel
    // must not drop it (0x68 saw 0x2c8; epi ld retired P5 0x14c).
    logic fwd_keep;
  } entry_t;

  entry_t [DEPTH_SPEC-1:0]   speculative_queue_n, speculative_queue_q;
  entry_t [DEPTH_COMMIT-1:0] commit_queue_n, commit_queue_q;

  // keep a status count for both buffers
  logic [$clog2(DEPTH_SPEC):0] speculative_status_cnt_n, speculative_status_cnt_q;
  logic [$clog2(DEPTH_COMMIT):0] commit_status_cnt_n, commit_status_cnt_q;
  // A141 stationary speculative queue. Entries never move: a store is written
  // into a free slot and stays there until it commits, is cancelled or is
  // flushed. Program order is the age matrix `spec_older_q[i][j]` (entry i is
  // older than entry j), written once at insertion from the arrival's age
  // against every live entry and cleared with the entry; the commit head is
  // the live entry no live entry is older than, and the forwarding merge
  // picks, per byte, the candidate no younger candidate overrides. This
  // replaces the ring plus its insert/squash permutation (rank popcounts and
  // a DEPTH^2 gather of every payload field each cycle) — the core's worst
  // measured cone (3.7 ns, A128–A140). The ring pointers survive as debug
  // aliases: `speculative_read_pointer_q` is the head slot and
  // `speculative_write_pointer_q` the slot the next arrival takes.
  logic [DEPTH_SPEC-1:0]                 spec_valid_q;       // mirror of .valid, for the one-hot logic
  logic [DEPTH_SPEC-1:0][DEPTH_SPEC-1:0] spec_older_q, spec_older_n;
  logic [DEPTH_SPEC-1:0]                 spec_head_oh, spec_ins_oh, spec_remove, spec_pop;
  logic [$clog2(DEPTH_SPEC)-1:0]         speculative_read_pointer_q, speculative_write_pointer_q;
  // Commit Queue
  logic [$clog2(DEPTH_COMMIT)-1:0] commit_read_pointer_n, commit_read_pointer_q;
  logic [$clog2(DEPTH_COMMIT)-1:0] commit_write_pointer_n, commit_write_pointer_q;

  // hyp8 OoOEn is 1, so the in-order SMT keep is false for every
  // profile this package selects (including SMT2). The struct expression
  // does not fold and was the fwd_keep cone.
  localparam bit LEGACY_SMT_KEEP = 1'b0;
  // pragma translate_off
  initial begin
    assert (!(G6LCCfg.SuperscalarEn && G6LCCfg.NrHarts > 1 && !G6LCCfg.OoOEn))
      else $error("store_buffer: LEGACY_SMT_KEEP literal 0 does not match this config");
  end
  // pragma translate_on

  // Program order under OoO: circular trans_id distance from the oldest live
  // instruction, the same key g6lc_lsq.sv applies with commit_ptr_i.
  function automatic logic ooo_older(input logic [G6LCCfg.TRANS_ID_BITS-1:0] a,
                                     input logic [G6LCCfg.TRANS_ID_BITS-1:0] b);
    // T6b-4b: age distances are anchored at the reclaim pointer (oldest live
    // slot), not the port-0 commit slot — under per-hart commit heads they
    // can diverge.
    return g6lc_ooo_pkg::ooo_age_older(G6LCCfg.TRANS_ID_BITS, 32'(a), 32'(b), 32'(oldest_live_tid_i));
  endfunction

  // Visibility of a *speculative* store to the querying load. Commit-queue
  // entries are deliberately NOT filtered by this: they are architecturally
  // older by construction, and their trans_ids may already have been recycled
  // by younger instructions, so an age test there would reject valid data.
  function automatic logic spec_visible(input logic [G6LCCfg.TRANS_ID_BITS-1:0] sid);
    return !G6LCCfg.OoOEn || ooo_older(sid, load_trans_id_i);
  endfunction

  // Paddr equality at the data-lane granularity (XLEN/8 bytes). The STQ
  // forward and the page-offset interlock below must see every store whose
  // bytes fall inside the load's lane, not only a store at the load's own
  // byte address: byte-exact matching let a doubleword load pass two
  // younger-than-nothing/older-than-the-load narrow stores at +2/+4 of its
  // lane with neither forward nor stall and read the stale line (T31,
  // ooo_mem_min stage 47; Linux printk's printf_spec bitfields on
  // g6lc64_ooo). Lanes are be-masked, so a lane match forwards exactly the
  // written bytes; a lane-crossing access is split or trapped before here.
  localparam int unsigned LANE_W = $clog2(G6LCCfg.XLEN / 8);
  function automatic logic pa_eq(input logic [G6LCCfg.PLEN-1:0] a,
                                 input logic [G6LCCfg.PLEN-1:0] b);
    return a[G6LCCfg.PLEN-1:LANE_W] == b[G6LCCfg.PLEN-1:LANE_W];
  endfunction
  function automatic logic po_eq(input logic [11:0] a, input logic [11:0] b);
    return a[11:LANE_W] == b[11:LANE_W];
  endfunction

  // U7c: a cbo.zero entry's coverage is its whole cache line (the stored
  // address is the line-aligned base). Match by line tag so loads anywhere
  // in the line stall on the pending entry and forward zeros.
  function automatic logic cboz_covers(input cbo_t cop,
                                       input logic [G6LCCfg.PLEN-1:0] entry_pa,
                                       input logic [G6LCCfg.PLEN-1:0] byte_pa);
    return G6LCCfg.RVZiCboz && (cop == CBO_ZERO) &&
           (entry_pa[G6LCCfg.PLEN-1:CBOZ_OFF_W] ==
            byte_pa[G6LCCfg.PLEN-1:CBOZ_OFF_W]);
  endfunction

  // T6b-4b: under mixed-resident OoO commit, a store may only commit when it
  // is the speculative-queue head — the queue is program-age ordered, so an
  // out-of-ring-order peer-hart commit of a younger store must not evict the
  // uncommitted head to memory. The mismatch stalls the store at the commit
  // port; tid-keyed eviction is T6b-4b' if the stall stat is material.
  localparam bit MixCommit = G6LCCfg.OoOEn &&
                            (G6LCCfg.NrHarts > 1) && !G6LCCfg.SmtDrainedHandoff;
  logic spec_head_valid, spec_head_mismatch;
  // lowest set bit as a log-depth prefix OR (A140: `x & (~x+1)` maps as a carry chain)
  function automatic logic [DEPTH_SPEC-1:0] spec_lowest_set(input logic [DEPTH_SPEC-1:0] x);
    logic [DEPTH_SPEC-1:0] below;
    below = x << 1;
    for (int unsigned l = 1; l < DEPTH_SPEC; l = l << 1) below = below | (below << l);
    return x & ~below;
  endfunction

  // ---------------- helper records ----------------
  // stb_insert S2 writeback record
  logic                    s1_v;
  logic                    s2_wr_valid;
  logic [DEPTH_SPEC-1:0]   s2_slot_oh;
  entry_t                  s2_entry;
  logic [DEPTH_SPEC-1:0]   s2_older_row, s2_older_col;
  // stb_commit records
  logic [DEPTH_SPEC-1:0]   commit_pop_oh;
  entry_t                  spec_head;
  logic                    commit_push_valid;
  entry_t                  commit_push_entry;
  logic                    commit_pend_v;
  // stb_drain records
  entry_t [DEPTH_COMMIT-1:0] cmt_queue_n;
  logic                    drain_commit_ready, drain_no_st_pending, drain_gnt;

  // ----------------------------------------
  // Speculative Queue - Core Interface
  // ----------------------------------------
  // entries still live after this cycle's removals — the S2 writeback
  // masks its captured age row/column against this so the matrix never
  // references a slot that left while the record was staged.
  logic [DEPTH_SPEC-1:0] live_after;
  // hyp8 S2: removals (commit pop, per-entry cancel verdict, flush) plus the
  // stb_insert writeback are applied here; the arrival capture itself is
  // staged one cycle earlier inside stb_insert.
  always_comb begin : core_if
    automatic logic lgcy_flush_keep;
    automatic logic [DEPTH_SPEC-1:0] cancel_hit;
    speculative_queue_n = speculative_queue_q;
    spec_older_n        = spec_older_q;
    spec_ins_oh         = s2_slot_oh;

    // FSE S4 younger-only cancel: the verdict is a property of the entry,
    // looked up on its registered trans_id; the arrival is never cancelled
    // (the push guard tests trans_id_i). G1ah SMT+SS keeps fwd_keep entries.
    for (int unsigned i = 0; i < DEPTH_SPEC; i++)
      cancel_hit[i] = spec_valid_q[i] && cancelled_mask_i[speculative_queue_q[i].trans_id];
    lgcy_flush_keep = flush_i && LEGACY_SMT_KEEP;
    for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
      if (LEGACY_SMT_KEEP) begin
`ifdef G6LC_FETCH_B
        // I13 (B): on flush or cancel keep fwd_keep and the not-cancelled
        spec_remove[i] = spec_valid_q[i] && cancel_hit[i] && !speculative_queue_q[i].fwd_keep;
`else
        // A: on flush keep only fwd_keep; on cancel keep fwd_keep and the not-cancelled
        spec_remove[i] = spec_valid_q[i] && !speculative_queue_q[i].fwd_keep &&
                         (cancel_hit[i] || flush_i);
`endif
      end else begin
        // SI / no G1ah: a flush evicts every speculative store; a cancel its tids
        spec_remove[i] = spec_valid_q[i] && (flush_i || cancel_hit[i]);
      end
    end
    live_after = spec_valid_q & ~commit_pop_oh & ~spec_remove;

    // removals first: valid off, age rows and columns cleared
    for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
      if (commit_pop_oh[i] || spec_remove[i]) begin
        speculative_queue_n[i].valid = 1'b0;
        speculative_queue_n[i].fwd_keep = 1'b0;
`ifndef G6LC_MUT_STQ_FLUSH_WP_Q
        // Review mutation (A141, the T35 leaf): leave the age bits of a
        // leaving entry in place; spec_order_cleared must trip.
        for (int unsigned j = 0; j < DEPTH_SPEC; j++) begin
          spec_older_n[i][j] = 1'b0;
          spec_older_n[j][i] = 1'b0;
        end
`endif
      end
    end
    // G1ah: a spec store that a live load already forwarded from must drain
    if (LEGACY_SMT_KEEP && load_paddr_valid_i) begin
      for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
        if (speculative_queue_n[i].valid &&
            pa_eq(speculative_queue_n[i].address, load_paddr_i)) begin
          speculative_queue_n[i].fwd_keep = 1'b1;
        end
      end
    end
    // the S2 insertion: the staged record's payload, age row and column,
    // masked to the still-live slots (a slot that left while the record
    // was staged must not keep an age bit — spec_order_cleared).
    if (s2_wr_valid) begin
      for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
        if (s2_slot_oh[i]) begin
          speculative_queue_n[i] = s2_entry;
          for (int unsigned j = 0; j < DEPTH_SPEC; j++) begin
            spec_older_n[j][i] = s2_older_row[j] && live_after[j];
            spec_older_n[i][j] = s2_older_col[j] && live_after[j];
          end
        end
      end
    end

  end

  // hyp8: speculative occupancy, parameterized over DEPTH_SPEC — this is
  // occupancy, not an 8-entry assumption. A serial cnt += inside the
  // queue process was the cone; the leaves are the post-removal/
  // post-insertion valid bits padded to a power of two and reduced as a
  // balanced tree.
  localparam int unsigned SPEC_PAD   = 1 << $clog2(DEPTH_SPEC);
  localparam int unsigned SPEC_PAD_L = $clog2(SPEC_PAD);
  localparam int unsigned SPEC_CNT_W = $clog2(DEPTH_SPEC + 1);
  logic [SPEC_PAD-1:0]                     spec_vb;
  logic [SPEC_PAD_L:0][SPEC_PAD-1:0][SPEC_CNT_W-1:0] spec_lvl;
  for (genvar i = 0; i < SPEC_PAD; i++) begin : gen_spec_vb
    if (i < DEPTH_SPEC) begin : gen_leaf
      assign spec_vb[i]    = speculative_queue_n[i].valid;
      assign spec_lvl[0][i] = SPEC_CNT_W'(spec_vb[i]);
    end else begin : gen_pad0
      assign spec_vb[i]    = 1'b0;
      assign spec_lvl[0][i] = '0;
    end
  end
  for (genvar l = 0; l < SPEC_PAD_L; l++) begin : gen_spec_cnt
    for (genvar i = 0; i < (SPEC_PAD >> (l + 1)); i++) begin : gen_node
      assign spec_lvl[l+1][i] = spec_lvl[l][2*i] + spec_lvl[l][2*i+1];
    end
    for (genvar i = (SPEC_PAD >> (l + 1)); i < SPEC_PAD; i++) begin : gen_pad
      assign spec_lvl[l+1][i] = '0;
    end
  end
  assign speculative_status_cnt_n = spec_lvl[SPEC_PAD_L][0];

  // hyp8: credit for the NEXT store-unit admission — a registered ready
  // alone was unsound: count_n already includes the S1->array
  // installation, but the same-cycle arrival must be charged before
  // another credit is advertised or the pending record and the arrival
  // can both claim the last free slot. This is the same-cycle
  // reserved-capacity calculation instead of a flow-through credit.
  // commit_pop is NOT added back: the popped head's removal is already
  // reflected in count_n. st_valid arrives on the store unit's
  // registered VALID_STORE, so this does not create a ready->valid loop.
  localparam int unsigned CREDIT_W = $clog2(DEPTH_SPEC + 2);
  logic incoming_store;
  assign incoming_store = valid_i && !flush_i && !cancelled_mask_i[trans_id_i];
  assign ready_o = !flush_i &&
    ((CREDIT_W'(speculative_status_cnt_n) + CREDIT_W'(incoming_store)) < CREDIT_W'(DEPTH_SPEC));

  // ----------------------------------------
  // stb_insert — S1 capture / S2 writeback
  // ----------------------------------------
  logic [DEPTH_SPEC-1:0][G6LCCfg.TRANS_ID_BITS-1:0] spec_tids;
  for (genvar i = 0; i < DEPTH_SPEC; i++) begin : gen_spec_tid
    assign spec_tids[i]   = speculative_queue_q[i].trans_id;
    assign spec_valid_q[i] = speculative_queue_q[i].valid;
  end

  stb_insert #(
      .G6LCCfg   (G6LCCfg),
      .DEPTH_SPEC(DEPTH_SPEC),
      .entry_t   (entry_t),
      .cbo_t     (cbo_t),
      .AGE_EN    (G6LCCfg.OoOEn)
  ) i_stb_insert (
      .clk_i, .rst_ni, .flush_i,
      .cancelled_mask_i,
      .valid_i, .paddr_i, .data_i, .be_i, .data_size_i, .cbo_op_i,
      .trans_id_i, .st_hart_i,
      .fwd_keep_i (LEGACY_SMT_KEEP && load_paddr_valid_i &&
                   pa_eq(paddr_i, load_paddr_i)),
      .spec_valid_i      (spec_valid_q),
      .spec_tid_i        (spec_tids),
      .live_after_i      (live_after),
      .oldest_live_tid_i,
      .s1_v_o            (s1_v),
      .s2_wr_valid_o     (s2_wr_valid),
      .s2_slot_oh_o      (s2_slot_oh),
      .s2_entry_o        (s2_entry),
      .s2_older_row_o    (s2_older_row),
      .s2_older_col_o    (s2_older_col)
  );

  // ----------------------------------------
  // stb_commit — head select + spec->commit pend
  // ----------------------------------------
  stb_commit #(
      .G6LCCfg   (G6LCCfg),
      .DEPTH_SPEC(DEPTH_SPEC),
      .entry_t   (entry_t),
      .MIX_COMMIT(MixCommit)
  ) i_stb_commit (
      .clk_i, .rst_ni, .flush_i,
      .spec_valid_i   (spec_valid_q),
      .spec_older_i   (spec_older_q),
      .spec_entries_i (speculative_queue_q),
      .commit_i,
      .commit_trans_id_i,
      .head_oh_o      (spec_head_oh),
      .head_entry_o   (spec_head),
      .head_valid_o   (spec_head_valid),
      .head_mismatch_o(spec_head_mismatch),
      .pop_oh_o       (commit_pop_oh),
      .push_valid_o   (commit_push_valid),
      .push_entry_o   (commit_push_entry),
      .pend_v_o       (commit_pend_v)
  );

  // debug aliases of the retired ring pointers (census, leaf benches)
  always_comb begin
    speculative_read_pointer_q  = '0;
    speculative_write_pointer_q = '0;
    for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
      if (spec_head_oh[i]) speculative_read_pointer_q  = speculative_read_pointer_q  | $clog2(DEPTH_SPEC)'(i);
      if (spec_ins_oh[i])  speculative_write_pointer_q = speculative_write_pointer_q | $clog2(DEPTH_SPEC)'(i);
    end
  end

  assign store_buffer_empty_o = (speculative_status_cnt_q == 0) && !s1_v && no_st_pending_o;
  // hyp8: a commit in flight between the spec pop and the queue push is
  // still a pending store.
  assign no_st_pending_o = drain_no_st_pending && !commit_pend_v;

  // hyp8: commit readiness additionally requires the committing store to be
  // INSTALLED in the speculative queue. Arrivals are staged (stb_insert S1
  // capture, S2 writeback), so a store that completed through valid_i this
  // cycle is not visible to stb_commit for two edges; without this term a
  // commit_i can fire while the entry is still in flight — headless pop, no
  // pend push, and the committed store is silently lost (h34-r4:
  // speculative_buffer_underflow @649). Presence, not head, is deliberate:
  // ooo_commit_is_oldest still proves the popped head is the committing tid,
  // and MIX_COMMIT's head_mismatch path is unchanged.
  // There is no committing-hart input on this module; under a multi-hart
  // profile whose scoreboard tids are not globally unique, this match must
  // also compare the entry's .hart — recorded SMT2 obligation (single-hart
  // hyp8: tid identity is complete).
  logic commit_tid_present;
  always_comb begin
    commit_tid_present = 1'b0;
    for (int unsigned i = 0; i < DEPTH_SPEC; i++)
      commit_tid_present |= spec_valid_q[i] &&
          (speculative_queue_q[i].trans_id == commit_trans_id_i);
  end
  assign commit_ready_o  = drain_commit_ready && !commit_pend_v &&
                          (!G6LCCfg.OoOEn || commit_tid_present);

  assign rvfi_mem_paddr_o = spec_head.address;

  // ----------------------------------------
  // stb_drain — Commit Queue - Memory Interface
  // ----------------------------------------
  stb_drain #(
      .G6LCCfg     (G6LCCfg),
      .DEPTH_COMMIT(DEPTH_COMMIT),
      .CBOZ_BEATS  (CBOZ_BEATS),
      .CBOZ_STRIDE (CBOZ_STRIDE),
      .CBOZ_BEAT_W (CBOZ_BEAT_W),
      .entry_t     (entry_t),
      .cbo_t       (cbo_t),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t)
  ) i_stb_drain (
      .clk_i, .rst_ni,
      .commit_queue_i  (commit_queue_q),
      .rd_ptr_i        (commit_read_pointer_q),
      .wr_ptr_i        (commit_write_pointer_q),
      .cmt_cnt_i       (commit_status_cnt_q),
      .cboz_beat_i     (cboz_beat_q),
      .push_valid_i    (commit_push_valid),
      .push_entry_i    (commit_push_entry),
      .head_mismatch_i (spec_head_mismatch),
      .stall_st_pending_i,
      .req_port_i,
      .req_port_o,
      .commit_queue_o  (cmt_queue_n),
      .rd_ptr_o        (commit_read_pointer_n),
      .wr_ptr_o        (commit_write_pointer_n),
      .cmt_cnt_o       (commit_status_cnt_n),
      .cboz_beat_o     (cboz_beat_n),
      .commit_ready_o  (drain_commit_ready),
      .no_st_pending_o (drain_no_st_pending),
      .drain_gnt_o     (drain_gnt)
  );
  assign commit_queue_n = cmt_queue_n;

  // ------------------
  // Address Checker
  // ------------------
  // The load should return the data stored by the most recent store to the
  // same physical address.  The most direct way to implement this is to
  // maintain physical addresses in the store buffer.
  //
  // checks if the requested load is in the store buffer
  // page offsets are virtually and physically the same
  //
  // R3a: also hold a 1-cycle sticky match after the STQ entry leaves so the
  // load unit does not race the commit-queue → D$ wbuffer handoff. Without
  // this, WAIT_PAGE_OFFSET can release the cycle the store is granted into
  // the wbuffer and the load can sample stale D$ data (libfdt *nextoffset
  // stays 0 → OpenSBI FDT walk stuck). D$ wbuffer already forwards on hit;
  // the sticky covers the grant/accept bubble.
  logic page_offset_matches_now;
  // N1d: while the commit head is an unpublished load, every speculative
  // entry's drain waits on commit progress that itself waits on this LSU —
  // a circular wait. Suppress the speculative stall terms only: the
  // commit-queue and sticky terms drain autonomously and must still gate.
  logic spec_stall_futile;
  assign spec_stall_futile = HEAD_GATE_EN && head_phys_pending_i;
  logic [G6LCCfg.PLEN-1:0] page_offset_sticky_pa_q;
  logic                    page_offset_sticky_v_q;
  logic                    page_offset_sticky_po_v_q;  // [11:0]-only sticky
  logic [11:0]             page_offset_sticky_po_q;
  logic                    po_commit_match, po_spec_match;
  // G1ao: last live STQ forward, replayed to the next same-PA load.
  logic                          g1ao_hold_v_q, g1ao_hold_hit;
  logic [G6LCCfg.PLEN-1:0]       g1ao_hold_pa_q;
  logic [G6LCCfg.XLEN-1:0]       g1ao_hold_data_q;
  logic [(G6LCCfg.XLEN/8)-1:0]   g1ao_hold_be_q, st_fwd_live_be;

  always_comb begin : address_checker
    // R3a: **stall** on [11:0] always (classic — never miss stack RAW).
    // load_paddr is vaddr (see load_unit); full-PA-only stall missed stack RAW
    // when store queue holds paddr form. Forward remains full-PA only.
    // cont.11 false-alias FDT vs stack is still open (next_tag tag=9).
    page_offset_matches_now = 1'b0;
    po_commit_match = 1'b0;
    po_spec_match   = 1'b0;

    for (int unsigned i = 0; i < DEPTH_COMMIT; i++) begin
      if (commit_queue_q[i].valid &&
          (po_eq(commit_queue_q[i].address[11:0], page_offset_i) ||
           (G6LCCfg.RVZiCboz &&
            commit_queue_q[i].cbo_op == CBO_ZERO &&
            ((commit_queue_q[i].address[11:0] >> CBOZ_OFF_W) ==
             (page_offset_i >> CBOZ_OFF_W))))) begin
        page_offset_matches_now = 1'b1;
        po_commit_match = 1'b1;
        break;
      end
    end
    for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
      // Age filter is load-bearing for LIVENESS here, not just for data:
      // commit is in-order, so an older load that stalls on a YOUNGER store
      // can never progress -- that store cannot commit until the load retires.
      if (!spec_stall_futile &&
          speculative_queue_q[i].valid &&
          spec_visible(speculative_queue_q[i].trans_id) &&
          (po_eq(speculative_queue_q[i].address[11:0], page_offset_i) ||
           (G6LCCfg.RVZiCboz &&
            speculative_queue_q[i].cbo_op == CBO_ZERO &&
            ((speculative_queue_q[i].address[11:0] >> CBOZ_OFF_W) ==
             (page_offset_i >> CBOZ_OFF_W))))) begin
        page_offset_matches_now = 1'b1;
        po_spec_match = 1'b1;
        break;
      end
    end
    // hyp8: the pend record between spec pop and commit-queue push is
    // already architectural — an unconditional committed-source match
    // like the queue entries above, never gated by spec_stall_futile.
    if (commit_push_valid &&
        (po_eq(commit_push_entry.address[11:0], page_offset_i) ||
         (G6LCCfg.RVZiCboz &&
          commit_push_entry.cbo_op == CBO_ZERO &&
          ((commit_push_entry.address[11:0] >> CBOZ_OFF_W) ==
           (page_offset_i >> CBOZ_OFF_W))))) begin
      page_offset_matches_now = 1'b1;
      po_commit_match = 1'b1;
    end
    if (!spec_stall_futile && valid_without_flush_i && spec_visible(trans_id_i) &&
        (po_eq(paddr_i[11:0], page_offset_i) ||
         (G6LCCfg.RVZiCboz && cbo_op_i == CBO_ZERO &&
          ((paddr_i[11:0] >> CBOZ_OFF_W) == (page_offset_i >> CBOZ_OFF_W))))) begin
      page_offset_matches_now = 1'b1;
      po_spec_match = 1'b1;
    end
    // hyp8: the staged S1 record occupies a speculative slot already — it
    // must match the interlock like a queued entry.
    if (!spec_stall_futile && s1_v && spec_visible(s2_entry.trans_id) &&
        (po_eq(s2_entry.address[11:0], page_offset_i) ||
         (G6LCCfg.RVZiCboz && s2_entry.cbo_op == CBO_ZERO &&
          ((s2_entry.address[11:0] >> CBOZ_OFF_W) == (page_offset_i >> CBOZ_OFF_W))))) begin
      page_offset_matches_now = 1'b1;
      po_spec_match = 1'b1;
    end

    // G1m: interlock only for a live load (load_paddr_valid). Idle/store
    // heads were matching their own [11:0] and arming sticky.
    page_offset_matches_o = load_paddr_valid_i &&
        (page_offset_matches_now ||
         (page_offset_sticky_po_v_q && po_eq(page_offset_sticky_po_q, page_offset_i)) ||
         (page_offset_sticky_v_q &&
          pa_eq(page_offset_sticky_pa_q, load_paddr_i)) ||
         (LEGACY_SMT_KEEP &&
          g1ao_hold_v_q && pa_eq(g1ao_hold_pa_q, load_paddr_i)));
    // The sticky flags re-arm from the live match itself (`page_offset_matches_now`
    // branch below), so they cannot tell a draining store from this one; the
    // drain window is bounded by the D$ wbuffer instead: speculative-only means
    // no committed entry in the lane and nothing left in the wbuffer.
    page_offset_spec_only_o = load_paddr_valid_i && po_spec_match && !po_commit_match &&
        dcache_wbuffer_empty_i;
  end

  // ------------------ Forward path ------------------
  // hyp8: StoreFwdCycles==3 — the staged F1-F3 pipeline answers fwd_req_i;
  // the legacy st_fwd_* pins hold the last completed response (+3).
  // StoreFwdCycles==1 — the emit's same-cycle merge on the live inputs.
  localparam int unsigned FWD_TAG_W =
      (G6LCCfg.NrLoadBufEntries > 1) ? $clog2(G6LCCfg.NrLoadBufEntries) : 1;
  logic                          f3_valid, f3_possible;
  logic [G6LCCfg.XLEN-1:0]       f3_data;
  logic [(G6LCCfg.XLEN/8)-1:0]   f3_be;
  logic [FWD_TAG_W-1:0]          f3_tag;
  logic                          fwd_hold_v_q;
  logic [G6LCCfg.XLEN-1:0]       fwd_hold_data_q;
  logic [(G6LCCfg.XLEN/8)-1:0]   fwd_hold_be_q;

  generate
    if (HypCfg.StoreFwdCycles > 1) begin : gen_fwd_pipe
      // arrival candidates: the live valid_without_flush term and the
      // staged S1 record (the entry about to land)
      logic [1:0]                       ins_valid;
      logic [1:0][G6LCCfg.TRANS_ID_BITS-1:0] ins_tid;
      logic [1:0][HID_W-1:0]            ins_hart;
      logic [1:0][G6LCCfg.PLEN-1:0]     ins_pa;
      logic [1:0][G6LCCfg.XLEN-1:0]     ins_data;
      logic [1:0][(G6LCCfg.XLEN/8)-1:0] ins_be;
      cbo_t [1:0]                       ins_cbo;
      assign ins_valid[0] = valid_without_flush_i && !cancelled_mask_i[trans_id_i];
      assign ins_tid[0]   = trans_id_i;
      assign ins_hart[0]  = st_hart_i;
      assign ins_pa[0]    = paddr_i;
      assign ins_data[0]  = data_i;
      assign ins_be[0]    = be_i;
      assign ins_cbo[0]   = cbo_op_i;
      assign ins_valid[1] = s2_wr_valid;
      assign ins_tid[1]   = s2_entry.trans_id;
      assign ins_hart[1]  = s2_entry.hart;
      assign ins_pa[1]    = s2_entry.address;
      assign ins_data[1]  = s2_entry.data;
      assign ins_be[1]    = s2_entry.be;
      assign ins_cbo[1]   = s2_entry.cbo_op;

      logic [DEPTH_COMMIT-1:0] cmt_valid;
      for (genvar i = 0; i < DEPTH_COMMIT; i++) begin : gen_cmtv
        assign cmt_valid[i] = commit_queue_q[i].valid;
      end

      stb_fwd #(
          .G6LCCfg     (G6LCCfg),
          .DEPTH_SPEC  (DEPTH_SPEC),
          .DEPTH_COMMIT(DEPTH_COMMIT),
          .CBOZ_OFF_W  (CBOZ_OFF_W),
          .TAG_W       (FWD_TAG_W),
          .AGE_EN      (G6LCCfg.OoOEn),
          .HART_OWN    (HART_OWN),
          .entry_t     (entry_t),
          .cbo_t       (cbo_t)
      ) i_stb_fwd (
          .clk_i, .rst_ni, .flush_i,
          .req_valid_i (fwd_req_i.valid),
          .req_pa_i    (fwd_req_i.pa),
          .req_size_i  (fwd_req_i.size),
          .req_tid_i   (fwd_req_i.tid),
          .req_hart_i  (fwd_req_i.hart),
          .req_tag_i   (fwd_req_i.tag),
          .spec_entries_i (speculative_queue_q),
          .spec_valid_i   (spec_valid_q),
          .spec_older_i   (spec_older_q),
          .cmt_entries_i  (commit_queue_q),
          .cmt_valid_i    (cmt_valid),
          .cmt_rd_ptr_i   (commit_read_pointer_q),
          .cmt_pending_valid_i (commit_push_valid),
          .cmt_pending_entry_i (commit_push_entry),
          .ins_valid_i (ins_valid),
          .ins_tid_i   (ins_tid),
          .ins_hart_i  (ins_hart),
          .ins_pa_i    (ins_pa),
          .ins_data_i  (ins_data),
          .ins_be_i    (ins_be),
          .ins_cbo_i   (ins_cbo),
          .oldest_live_tid_i,
          .rsp_valid_o    (f3_valid),
          .rsp_data_o     (f3_data),
          .rsp_be_o       (f3_be),
          .rsp_possible_o (f3_possible),
          .rsp_tag_o      (f3_tag)
      );

      assign fwd_rsp_o.valid            = f3_valid;
      assign fwd_rsp_o.data             = f3_data;
      assign fwd_rsp_o.be               = f3_be;
      assign fwd_rsp_o.forward_possible = f3_possible;
      assign fwd_rsp_o.tag              = f3_tag;

      // legacy pins: the last completed F3 response (+3 vs the live query)
      always_ff @(posedge clk_i or negedge rst_ni) begin : p_fwd_hold
        if (~rst_ni) begin
          fwd_hold_v_q    <= 1'b0;
          fwd_hold_data_q <= '0;
          fwd_hold_be_q   <= '0;
        end else if (flush_i) begin
          fwd_hold_v_q <= 1'b0;
        end else if (f3_valid) begin
          fwd_hold_v_q    <= f3_possible;
          fwd_hold_data_q <= f3_data;
          fwd_hold_be_q   <= f3_be;
        end
      end
      assign st_fwd_valid_o = fwd_hold_v_q;
      assign st_fwd_data_o  = fwd_hold_data_q;
      assign st_fwd_be_o    = fwd_hold_be_q;
      assign st_fwd_live_be = fwd_hold_be_q;
      assign g1ao_hold_hit  = 1'b0;
    end else begin : gen_fwd_live
      // StoreFwdCycles==1: the emit's same-cycle merge, verbatim.
      assign fwd_rsp_o = '0;
      always_comb begin : st_fwd_merge
        automatic logic [G6LCCfg.XLEN-1:0]     data_m;
        automatic logic [(G6LCCfg.XLEN/8)-1:0] be_m;
        automatic logic [$clog2(DEPTH_COMMIT)-1:0] cidx;
        data_m = '0;
        be_m   = '0;
        cidx   = '0;

        if (load_paddr_valid_i) begin
          // hyp8: A141 pairwise youngest-writer form for the commit-queue
          // layer — the emit's ring walk wrote data_m/be_m entry-by-entry
          // (a DEPTH_COMMIT x NB serial patch chain). Ring distance
          // rdist[i] = i - commit_read_pointer_q (mod DEPTH) is the age
          // rank: larger = younger = the walk's later writer. A byte takes
          // the candidate no younger candidate also writes.
          begin : cmt_fwd
            localparam int unsigned CW = $clog2(DEPTH_COMMIT);
            automatic logic [DEPTH_COMMIT-1:0] cent_match;
            automatic logic [DEPTH_COMMIT-1:0][(G6LCCfg.XLEN/8)-1:0] ccand, cwin;
            automatic logic [DEPTH_COMMIT-1:0][G6LCCfg.XLEN-1:0] cval;
            automatic logic [DEPTH_COMMIT-1:0][CW-1:0] rdist;
            for (int unsigned i = 0; i < DEPTH_COMMIT; i++) begin
              cent_match[i] = commit_queue_q[i].valid &&
                              (pa_eq(commit_queue_q[i].address, load_paddr_i) ||
                               cboz_covers(commit_queue_q[i].cbo_op,
                                           commit_queue_q[i].address, load_paddr_i));
              rdist[i] = CW'(i) - commit_read_pointer_q;
              cval[i]  = '0;
              for (int unsigned b = 0; b < (G6LCCfg.XLEN / 8); b++) begin
                if (G6LCCfg.RVZiCboz &&
                    commit_queue_q[i].cbo_op == CBO_ZERO) begin
                  // the entry zeroes its whole line: forward '0 for every
                  // load byte inside that line (per-byte check covers
                  // straddling loads).
                  ccand[i][b] = cent_match[i] &&
                                cboz_covers(commit_queue_q[i].cbo_op,
                                            commit_queue_q[i].address,
                                            load_paddr_i + G6LCCfg.PLEN'(b));
                  cval[i][8*b+:8] = '0;
                end else begin
                  ccand[i][b] = cent_match[i] && commit_queue_q[i].be[b];
                  cval[i][8*b+:8] = commit_queue_q[i].data[8*b+:8];
                end
              end
            end
            for (int unsigned i = 0; i < DEPTH_COMMIT; i++) begin
              for (int unsigned b = 0; b < (G6LCCfg.XLEN / 8); b++) begin
                automatic logic younger_writes;
                younger_writes = 1'b0;
                for (int unsigned j = 0; j < DEPTH_COMMIT; j++)
                  younger_writes |= (rdist[j] > rdist[i]) && ccand[j][b];
                cwin[i][b] = ccand[i][b] && !younger_writes;
              end
            end
            for (int unsigned b = 0; b < (G6LCCfg.XLEN / 8); b++) begin
              automatic logic any_cand;
              automatic logic [7:0] byte_v;
              any_cand = 1'b0;
              byte_v   = '0;
              for (int unsigned i = 0; i < DEPTH_COMMIT; i++) begin
                any_cand |= ccand[i][b];
                byte_v   |= {8{cwin[i][b]}} & cval[i][8*b+:8];
              end
              if (any_cand) begin
                data_m[8*b+:8] = byte_v;
                be_m[b]        = 1'b1;
              end
            end
          end
          // A141: the speculative sources in program order without walking a
          // ring: every entry is a candidate per byte (older than the load, same
          // hart, lane or cbo.zero line match, byte written), and a byte takes
          // the candidate that no younger candidate also writes — the same
          // "last writer in program order wins" the ordered walk implemented.
          begin : spec_fwd
            automatic logic [DEPTH_SPEC-1:0] ent_match;
            automatic logic [DEPTH_SPEC-1:0][(G6LCCfg.XLEN/8)-1:0] cand, win;
            automatic logic [DEPTH_SPEC-1:0][G6LCCfg.XLEN-1:0] val;
            for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
              ent_match[i] = speculative_queue_q[i].valid &&
                             spec_visible(speculative_queue_q[i].trans_id) &&
                             (!HART_OWN || speculative_queue_q[i].hart == load_hart_i) &&
                             (pa_eq(speculative_queue_q[i].address, load_paddr_i) ||
                              cboz_covers(speculative_queue_q[i].cbo_op,
                                          speculative_queue_q[i].address, load_paddr_i));
              for (int unsigned b = 0; b < (G6LCCfg.XLEN / 8); b++) begin
                if (G6LCCfg.RVZiCboz && speculative_queue_q[i].cbo_op == CBO_ZERO) begin
                  cand[i][b] = ent_match[i] &&
                               cboz_covers(speculative_queue_q[i].cbo_op, speculative_queue_q[i].address,
                                           load_paddr_i + G6LCCfg.PLEN'(b));
                  val[i][8*b+:8] = '0;
                end else begin
                  cand[i][b] = ent_match[i] && speculative_queue_q[i].be[b];
                  val[i][8*b+:8] = speculative_queue_q[i].data[8*b+:8];
                end
              end
            end
            for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
              for (int unsigned b = 0; b < (G6LCCfg.XLEN / 8); b++) begin
                automatic logic younger_writes;
                younger_writes = 1'b0;
                for (int unsigned j = 0; j < DEPTH_SPEC; j++)
                  younger_writes |= spec_older_q[i][j] && cand[j][b];
                win[i][b] = cand[i][b] && !younger_writes;
              end
            end
            for (int unsigned b = 0; b < (G6LCCfg.XLEN / 8); b++) begin
              automatic logic any_cand;
              automatic logic [7:0] byte_v;
              any_cand = 1'b0;
              byte_v   = '0;
              for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
                any_cand |= cand[i][b];
                byte_v   |= {8{win[i][b]}} & val[i][8*b+:8];
              end
              // speculative stores are younger than every committed one
              if (any_cand) begin
                data_m[8*b+:8] = byte_v;
                be_m[b]        = 1'b1;
              end
            end
          end
          // hyp8: the staged S1 record is an arriving candidate like the
          // live valid_without_flush term.
          if (s2_wr_valid && spec_visible(s2_entry.trans_id) &&
              (!HART_OWN || s2_entry.hart == load_hart_i) &&
              (pa_eq(s2_entry.address, load_paddr_i) ||
               cboz_covers(s2_entry.cbo_op, s2_entry.address, load_paddr_i))) begin
            for (int unsigned b = 0; b < (G6LCCfg.XLEN / 8); b++) begin
              if (s2_entry.be[b]) begin
                data_m[8*b+:8] = (G6LCCfg.RVZiCboz && s2_entry.cbo_op == CBO_ZERO)
                                   ? '0 : s2_entry.data[8*b+:8];
                be_m[b]        = 1'b1;
              end
            end
          end
          if (valid_without_flush_i && spec_visible(trans_id_i) &&
              (!HART_OWN || st_hart_i == load_hart_i) &&
              (pa_eq(paddr_i, load_paddr_i) ||
               cboz_covers(cbo_op_i, paddr_i, load_paddr_i))) begin
            if (G6LCCfg.RVZiCboz && cbo_op_i == CBO_ZERO) begin
              for (int unsigned b = 0; b < (G6LCCfg.XLEN / 8); b++) begin
                if (cboz_covers(cbo_op_i, paddr_i, load_paddr_i + G6LCCfg.PLEN'(b))) begin
                  data_m[8*b+:8] = '0;
                  be_m[b]        = 1'b1;
                end
              end
            end else begin
              for (int unsigned b = 0; b < (G6LCCfg.XLEN / 8); b++) begin
                if (be_i[b]) begin
                  data_m[8*b+:8] = data_i[8*b+:8];
                  be_m[b]        = 1'b1;
                end
              end
            end
          end
        end

        st_fwd_live_be = be_m;
        g1ao_hold_hit  = 1'b0;
        // G1ao: if the live STQ already drained, replay the last
        // forward to a same-PA load. ld t1 took 0x2c8; ld t3 of
        // 8(sp) missed. SMT+SS. Not G1af (all spec nofwd).
        if (LEGACY_SMT_KEEP &&
            !(|be_m) && g1ao_hold_v_q && load_paddr_valid_i &&
            pa_eq(g1ao_hold_pa_q, load_paddr_i)) begin
          data_m        = g1ao_hold_data_q;
          be_m          = g1ao_hold_be_q;
          g1ao_hold_hit = 1'b1;
        end
        st_fwd_data_o  = data_m;
        st_fwd_be_o    = be_m;
        // R3a cont.13: keep STQ forward on; nofwd + store-side sticky still −4,
        // so residual is not STQ→wbuffer *nextoffset alone.
        st_fwd_valid_o = |be_m;
      end
    end
  endgenerate

  // R3a cont.13: **store-side** sticky on STQ→D$ grant.
  // Load-side sticky only armed when a load was checking during STQ occupancy;
  // the caller's post-return load of libfdt *nextoffset often issues after the
  // store left the STQ, so match_now was never seen and sticky never set.
  // Capture the store address when it is granted into the D$ wbuffer and hold
  // until wbuffer_empty so load_unit condition (2) covers the handoff.
  logic st_to_wbuf_grant;
  assign st_to_wbuf_grant =
      drain_gnt &&
      (commit_queue_q[commit_read_pointer_q].cbo_op == CBO_NONE ||
       req_port_i.data_rvalid);

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_page_offset_sticky
    if (~rst_ni) begin
      page_offset_sticky_v_q    <= 1'b0;
      page_offset_sticky_pa_q   <= '0;
      page_offset_sticky_po_v_q <= 1'b0;
      page_offset_sticky_po_q   <= '0;
    end else if (flush_i) begin
      page_offset_sticky_v_q    <= 1'b0;
      page_offset_sticky_po_v_q <= 1'b0;
    end else if (st_to_wbuf_grant) begin
      // Store accepted into D$ hierarchy — remember its [11:0]/full PA
      page_offset_sticky_po_v_q <= 1'b1;
      page_offset_sticky_po_q   <= commit_queue_q[commit_read_pointer_q].address[11:0];
      page_offset_sticky_v_q    <= 1'b1;
      page_offset_sticky_pa_q   <= commit_queue_q[commit_read_pointer_q].address;
    end else if (page_offset_matches_now) begin
      // Also arm while load is matching STQ (covers same-cycle forward path)
      page_offset_sticky_po_v_q <= 1'b1;
      page_offset_sticky_po_q   <= page_offset_i;
      if (load_paddr_valid_i) begin
        page_offset_sticky_v_q  <= 1'b1;
        page_offset_sticky_pa_q <= load_paddr_i;
      end
    end else if (page_offset_sticky_po_v_q && !dcache_wbuffer_empty_i) begin
      // Keep sticky until D$ wbuffer drains
    end else begin
      page_offset_sticky_v_q    <= 1'b0;
      page_offset_sticky_po_v_q <= 1'b0;
    end
  end

  // G1ao: capture a live STQ forward; replay once to a later same-PA
  // load after the store drains. Clear on flush, a newer store to
  // that PA, a different-PA load, or after the replay is consumed.
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_g1ao_hold
    if (~rst_ni) begin
      g1ao_hold_v_q    <= 1'b0;
      g1ao_hold_pa_q   <= '0;
      g1ao_hold_data_q <= '0;
      g1ao_hold_be_q   <= '0;
    end else if (flush_i ||
                 !(LEGACY_SMT_KEEP)) begin
      g1ao_hold_v_q <= 1'b0;
    end else if (valid_i && g1ao_hold_v_q &&
                 pa_eq(paddr_i, g1ao_hold_pa_q)) begin
      g1ao_hold_v_q <= 1'b0;
    end else if (load_paddr_valid_i && |st_fwd_live_be) begin
      g1ao_hold_v_q    <= 1'b1;
      g1ao_hold_pa_q   <= load_paddr_i;
      g1ao_hold_data_q <= st_fwd_data_o;
      g1ao_hold_be_q   <= st_fwd_live_be;
    end else if (load_paddr_valid_i && g1ao_hold_hit) begin
      g1ao_hold_v_q <= 1'b0;
    end else if (load_paddr_valid_i && g1ao_hold_v_q &&
                 !pa_eq(g1ao_hold_pa_q, load_paddr_i)) begin
      g1ao_hold_v_q <= 1'b0;
    end
  end


  // registers
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_spec
    if (~rst_ni) begin
      speculative_queue_q         <= '{default: 0};
      spec_older_q                <= '0;
      speculative_status_cnt_q    <= '0;
    end else begin
      speculative_queue_q         <= speculative_queue_n;
      spec_older_q                <= spec_older_n;
      speculative_status_cnt_q    <= speculative_status_cnt_n;
    end
  end

  // registers
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_commit
    if (~rst_ni) begin
      commit_queue_q         <= '{default: 0};
      commit_read_pointer_q  <= '0;
      commit_write_pointer_q <= '0;
      commit_status_cnt_q    <= '0;
      cboz_beat_q            <= '0;
    end else begin
      commit_queue_q         <= commit_queue_n;
      commit_read_pointer_q  <= commit_read_pointer_n;
      commit_write_pointer_q <= commit_write_pointer_n;
      commit_status_cnt_q    <= commit_status_cnt_n;
      cboz_beat_q            <= cboz_beat_n;
    end
  end

  ///////////////////////////////////////////////////////
  // assertions
  ///////////////////////////////////////////////////////

  //pragma translate_off
  // Witness for the forwarding age contract (T21e rewrite): every byte the
  // load takes must have a VISIBLE source -- a commit-queue entry (older by
  // construction), a speculative entry older than the load (spec_visible),
  // or the arriving store when it is older. hyp8: the witness runs on the
  // live pins (the ==1 merge) or the held F3 response (==3); the F1-F3
  // pipeline applies the same visible-source filter at its F1 stage.
  logic [(G6LCCfg.XLEN/8)-1:0] ooo_fwd_visible_cover;
  logic ooo_fwd_without_visible_source;
  always_comb begin
    ooo_fwd_visible_cover = '0;
    ooo_fwd_without_visible_source = 1'b0;
    if (G6LCCfg.OoOEn && load_paddr_valid_i && st_fwd_valid_o) begin
      for (int unsigned i = 0; i < DEPTH_COMMIT; i++)
        if (commit_queue_q[i].valid)
          for (int unsigned b = 0; b < (G6LCCfg.XLEN / 8); b++)
            if ((pa_eq(commit_queue_q[i].address, load_paddr_i) && commit_queue_q[i].be[b]) ||
                (G6LCCfg.RVZiCboz && cboz_covers(commit_queue_q[i].cbo_op, commit_queue_q[i].address,
                                                 load_paddr_i + G6LCCfg.PLEN'(b))))
              ooo_fwd_visible_cover[b] = 1'b1;
      for (int unsigned i = 0; i < DEPTH_SPEC; i++)
        if (speculative_queue_q[i].valid && spec_visible(speculative_queue_q[i].trans_id) &&
            (!HART_OWN || speculative_queue_q[i].hart == load_hart_i))
          for (int unsigned b = 0; b < (G6LCCfg.XLEN / 8); b++)
            if ((pa_eq(speculative_queue_q[i].address, load_paddr_i) && speculative_queue_q[i].be[b]) ||
                (G6LCCfg.RVZiCboz && cboz_covers(speculative_queue_q[i].cbo_op, speculative_queue_q[i].address,
                                                 load_paddr_i + G6LCCfg.PLEN'(b))))
              ooo_fwd_visible_cover[b] = 1'b1;
      if (valid_without_flush_i && spec_visible(trans_id_i) && (!HART_OWN || st_hart_i == load_hart_i))
        for (int unsigned b = 0; b < (G6LCCfg.XLEN / 8); b++)
          if ((pa_eq(paddr_i, load_paddr_i) && be_i[b]) ||
              (G6LCCfg.RVZiCboz && cboz_covers(cbo_op_i, paddr_i, load_paddr_i + G6LCCfg.PLEN'(b))))
            ooo_fwd_visible_cover[b] = 1'b1;
      ooo_fwd_without_visible_source = |(st_fwd_be_o & ~ooo_fwd_visible_cover);
    end
  end

  // assert that commit is never set when we are flushing this would be counter intuitive
  // as flush and commit are decided in the same stage
  commit_and_flush :
  assert property (@(posedge clk_i) rst_ni && flush_i |-> !commit_i)
  else $error("[Commit Queue] You are trying to commit and flush in the same cycle");

  speculative_buffer_overflow :
  assert property (@(posedge clk_i) rst_ni && (speculative_status_cnt_q == $bits(speculative_status_cnt_q)'(DEPTH_SPEC)) |-> !valid_i)
  else
    $error("[Speculative Queue] You are trying to push new data although the buffer is not ready");

  // Commit-edge facts shadowed into flops: a clocked property evaluates
  // its expression after the triggering edge's own state updates under
  // this simulator, so a consequence reading the just-popped head or the
  // post-commit count can never observe the pre-commit facts (post-pop the
  // head is empty and the count has already dropped). The shadows capture
  // those facts with ordinary flop semantics and the checks below read only
  // registered state, so they hold under either evaluation order.
  logic                              commit_shadow_v_q;
  logic                              commit_shadow_empty_q;
  logic                              commit_shadow_headless_q;
  logic [G6LCCfg.TRANS_ID_BITS-1:0]  commit_shadow_tid_q;
  logic [G6LCCfg.TRANS_ID_BITS-1:0]  commit_shadow_head_tid_q;
  always_ff @(posedge clk_i) begin
    commit_shadow_v_q        <= commit_i;
    commit_shadow_empty_q    <= commit_i && (speculative_status_cnt_q == 0);
    commit_shadow_headless_q <= commit_i && !spec_head_valid;
    commit_shadow_tid_q      <= commit_trans_id_i;
    commit_shadow_head_tid_q <= spec_head.trans_id;
  end

  speculative_buffer_underflow :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
                   commit_shadow_v_q |-> !commit_shadow_empty_q)
  else $error("[Speculative Queue] You are committing although there are no stores to commit");

  commit_buffer_overflow :
  assert property (@(posedge clk_i) rst_ni && (commit_status_cnt_q == $bits(commit_status_cnt_q)'(DEPTH_COMMIT)) |-> !commit_i)
  else $error("[Commit Queue] You are trying to commit a store although the buffer is full");

  // U5.4 OoO: the store handed to memory must be the one commit is retiring.
  // Commit is in program order, so the committing store is the oldest live
  // store and therefore the queue head. This catches any program-order
  // insertion error directly, at the handoff rather than in a later value.
  // The shadowed commit-edge facts are checked on the following edge (see
  // the shadow comment above): a same-edge read of spec_head already
  // reflects the pop when the property evaluates under this simulator.
  ooo_commit_is_oldest :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
                   (G6LCCfg.OoOEn && commit_shadow_v_q) |->
                   (!commit_shadow_headless_q &&
                    (commit_shadow_head_tid_q == commit_shadow_tid_q)))
  else
    $error("[Speculative Queue] OoO commit handoff took tid %0d, commit is retiring tid %0d",
           commit_shadow_head_tid_q, commit_shadow_tid_q);

  // U5.4 OoO: a store younger than the querying load must never reach it --
  // every forwarded byte has an older (visible) source.
  ooo_no_younger_forward :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
                   (G6LCCfg.OoOEn && load_paddr_valid_i && st_fwd_valid_o) |->
                   !ooo_fwd_without_visible_source)
  else $error("[Speculative Queue] OoO load tid %0d forwarded bytes %b with no older source (visible cover %b)",
              load_trans_id_i, st_fwd_be_o, ooo_fwd_visible_cover);

  // A141: the count is the number of live slots, and the age matrix is a
  // strict total order on the live entries (irreflexive, antisymmetric,
  // total between any two live entries, cleared with the entry) with
  // exactly one head whenever the queue is not empty.
  spec_cnt_is_popcount :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
                   (speculative_status_cnt_q == ($clog2(DEPTH_SPEC) + 1)'($countones(spec_valid_q))))
  else $error("[Speculative Queue] count %0d disagrees with %0d live slots",
              speculative_status_cnt_q, $countones(spec_valid_q));
  for (genvar i = 0; i < DEPTH_SPEC; i++) begin : gen_spec_order_assert
    for (genvar j = 0; j < DEPTH_SPEC; j++) begin : gen_spec_order_pair
      if (i == j) begin : gen_irrefl
        spec_order_irreflexive :
        assert property (@(posedge clk_i) disable iff (!rst_ni) !spec_older_q[i][i])
        else $error("[Speculative Queue] slot %0d older than itself", i);
      end else begin : gen_pair
        spec_order_total :
        assert property (@(posedge clk_i) disable iff (!rst_ni)
                         (spec_valid_q[i] && spec_valid_q[j]) |->
                         (spec_older_q[i][j] ^ spec_older_q[j][i]))
        else $error("[Speculative Queue] slots %0d/%0d live without a strict order", i, j);
        spec_order_cleared :
        assert property (@(posedge clk_i) disable iff (!rst_ni)
                         (!spec_valid_q[i] || !spec_valid_q[j]) |->
                         (!spec_older_q[i][j]))
        else $error("[Speculative Queue] stale age bit between %0d/%0d", i, j);
      end
    end
  end
  spec_one_head :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
                   (speculative_status_cnt_q != '0) |-> $onehot(spec_head_oh))
  else $error("[Speculative Queue] %0d live entries but head one-hot is %b",
              speculative_status_cnt_q, spec_head_oh);
  // The age matrix was written against the anchor of the insertion cycle.
  // It stays the program order only while the anchor (the scoreboard's
  // reclaim pointer, the oldest live slot) never passes a live store — true
  // by construction in the core, and what this check holds the environment to.
  if (G6LCCfg.OoOEn) begin : gen_spec_order_anchor
    for (genvar i = 0; i < DEPTH_SPEC; i++) begin : gen_i
      for (genvar j = 0; j < DEPTH_SPEC; j++) begin : gen_j
        if (i != j) begin : gen_pair
          spec_order_matches_anchor :
          assert property (@(posedge clk_i) disable iff (!rst_ni)
                           (spec_valid_q[i] && spec_valid_q[j]) |->
                           (spec_older_q[i][j] == ooo_older(speculative_queue_q[i].trans_id,
                                                           speculative_queue_q[j].trans_id)))
          else $error("[Speculative Queue] age of slots %0d/%0d (tids %0d/%0d) disagrees with the anchor %0d",
                      i, j, speculative_queue_q[i].trans_id, speculative_queue_q[j].trans_id, oldest_live_tid_i);
        end
      end
    end
  end

  if (G6LCCfg.OoOEn) begin : gen_sb_live_assert
    for (genvar i = 0; i < DEPTH_SPEC; i++) begin : gen_spec_entry_live
      ooo_spec_entry_live :
      assert property (@(posedge clk_i) disable iff (!rst_ni)
                       speculative_queue_q[i].valid |->
                       sb_live_i[speculative_queue_q[i].trans_id])
      else $error("[Speculative Queue] entry %0d holds tid %0d whose scoreboard slot is not live",
                  i, speculative_queue_q[i].trans_id);
    end
  end

  // U7c cbo.zero drain invariants: the beat counter may only be nonzero
  // while the commit head is a CBO_ZERO entry, and a cbo.zero's commit
  // entry must present the line-aligned base (the drain adds beat*stride).
  cboz_beat_only_zero_head :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
                   (cboz_beat_q != '0) |->
                   (commit_queue_q[commit_read_pointer_q].valid &&
                    commit_queue_q[commit_read_pointer_q].cbo_op == CBO_ZERO))
  else $error("[Commit Queue] cbo.zero beat counter advanced without a CBO_ZERO head");

  cboz_entry_line_aligned :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
                   (G6LCCfg.RVZiCboz && commit_i &&
                    speculative_queue_q[speculative_read_pointer_q].valid &&
                    speculative_queue_q[speculative_read_pointer_q].cbo_op ==
                    CBO_ZERO) |->
                   (speculative_queue_q[speculative_read_pointer_q].address[CBOZ_OFF_W-1:0] ==
                    '0))
  else $error("[Commit Queue] cbo.zero commit entry is not line-aligned");
  //pragma translate_on

//pragma translate_off
  // +stq_trace: store-buffer match-source/drain probe (diagnostic only).
  // Prints one line each time the union of the page-offset match sources,
  // the commit-queue occupancy and the drain handshake moves — a held
  // commit-class match leaves its owning source readable as the last line
  // (h33-r7: pom=1 poso=0 sbe=0 wbe=1 needed the queue entry vs pend vs
  // sticky vs gnt distinguished verbatim). +trace_from/+trace_to bound the
  // cycle window (default 0..3000); stq_lo/stq_hi remain as overrides.
  bit          stq_tr;
  int unsigned stq_lo, stq_hi;
  int unsigned stq_cyc = 0;
  logic [4095:0] stq_sig, stq_sig_q = '0;
  initial begin
    stq_tr = $test$plusargs("stq_trace");
    stq_lo = 0;
    stq_hi = 3000;
    void'($value$plusargs("trace_from=%d", stq_lo));
    void'($value$plusargs("trace_to=%d", stq_hi));
    void'($value$plusargs("stq_lo=%d", stq_lo));
    void'($value$plusargs("stq_hi=%d", stq_hi));
  end

  always_comb begin
    stq_sig = '0;
    stq_sig[0]     = |spec_valid_q;
    stq_sig[DEPTH_SPEC:1] = spec_valid_q;
    for (int unsigned i = 0; i < DEPTH_COMMIT; i++) begin
      stq_sig[16 + i*32 +: 32] = {commit_queue_q[i].valid,
                                  commit_queue_q[i].wait_rvalid,
                                  4'(commit_queue_q[i].cbo_op),
                                  commit_queue_q[i].trans_id,
                                  6'(i),
                                  commit_queue_q[i].address[11:0]};
    end
    stq_sig[288] = commit_push_valid;
    stq_sig[289] = commit_pend_v;
    stq_sig[301:290] = commit_push_entry.address[11:0];
    stq_sig[302 +: G6LCCfg.TRANS_ID_BITS] = commit_push_entry.trans_id;
    stq_sig[318 +: 4] = commit_read_pointer_q;
    stq_sig[322 +: 4] = commit_write_pointer_q;
    stq_sig[326 +: 5] = 5'(commit_status_cnt_q);
    stq_sig[331] = req_port_o.data_req;
    stq_sig[332] = req_port_o.data_we;
    stq_sig[344:333] = req_port_o.address_index;
    stq_sig[345] = req_port_i.data_gnt;
    stq_sig[346] = req_port_i.data_rvalid;
    stq_sig[347] = drain_gnt;
    stq_sig[348] = st_to_wbuf_grant;
    stq_sig[349] = stall_st_pending_i;
    stq_sig[350] = spec_head_mismatch;
    stq_sig[351] = page_offset_sticky_v_q;
    stq_sig[352] = page_offset_sticky_po_v_q;
    stq_sig[364:353] = page_offset_sticky_po_q;
    stq_sig[376:365] = page_offset_sticky_pa_q[11:0];
    stq_sig[377] = s1_v;
    stq_sig[378] = s2_wr_valid;
    stq_sig[390:379] = s2_entry.address[11:0];
    stq_sig[391 +: G6LCCfg.TRANS_ID_BITS] = s2_entry.trans_id;
    stq_sig[400] = page_offset_matches_now;
    stq_sig[401] = po_commit_match;
    stq_sig[402] = po_spec_match;
    stq_sig[403] = page_offset_matches_o;
    stq_sig[404] = page_offset_spec_only_o;
    stq_sig[405] = spec_stall_futile;
    stq_sig[406] = load_paddr_valid_i;
    stq_sig[418:407] = page_offset_i;
    stq_sig[430:419] = load_paddr_i[11:0];
    stq_sig[431] = commit_i;
    stq_sig[432 +: G6LCCfg.TRANS_ID_BITS] = commit_trans_id_i;
    stq_sig[440] = commit_ready_o;
    stq_sig[441] = no_st_pending_o;
    stq_sig[442] = drain_no_st_pending;
    stq_sig[443] = store_buffer_empty_o;
    stq_sig[444] = dcache_wbuffer_empty_i;
    stq_sig[445] = flush_i;
    stq_sig[446] = valid_i;
    stq_sig[447] = valid_without_flush_i;
    stq_sig[459:448] = paddr_i[11:0];
    stq_sig[460 +: G6LCCfg.TRANS_ID_BITS] = trans_id_i;
  end

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      stq_cyc  = 0;
      stq_sig_q = '0;
    end else if (stq_tr) begin
      stq_cyc++;
      if ((stq_sig != stq_sig_q) && (stq_cyc >= stq_lo) && (stq_cyc <= stq_hi)) begin
        $write("[stq] c=%0d sv=%b", stq_cyc, spec_valid_q);
        for (int unsigned i = 0; i < DEPTH_COMMIT; i++)
          $write(" cq%0d=v%b/w%b/cb%0d/pa%x/t%0d", i,
                 commit_queue_q[i].valid, commit_queue_q[i].wait_rvalid,
                 commit_queue_q[i].cbo_op, commit_queue_q[i].address[11:0],
                 commit_queue_q[i].trans_id);
        $display(" pushv=%b pend=%b pushpa=%x pusht=%0d rdp=%0d wrp=%0d ccnt=%0d dreq=%b dwe=%b aidx=%x gnt=%b rvld=%b dgnt=%b s2w=%b ssp=%b hmis=%b stkv=%b stkpov=%b stkpo=%x stkpa=%x s1v=%b s2v=%b s2pa=%x s2tid=%0d mnow=%b pcm=%b psm=%b pom=%b poso=%b sfut=%b lpv=%b poi=%x lpa=%x cmti=%b cmtid=%0d crdy=%b nsp=%b dnsp=%b sbe=%b wbe=%b fls=%b vi=%b vwf=%b paddr=%x tid=%0d",
                 commit_push_valid, commit_pend_v,
                 commit_push_entry.address[11:0], commit_push_entry.trans_id,
                 commit_read_pointer_q, commit_write_pointer_q,
                 commit_status_cnt_q,
                 req_port_o.data_req, req_port_o.data_we,
                 req_port_o.address_index, req_port_i.data_gnt,
                 req_port_i.data_rvalid, drain_gnt, st_to_wbuf_grant,
                 stall_st_pending_i, spec_head_mismatch,
                 page_offset_sticky_v_q, page_offset_sticky_po_v_q,
                 page_offset_sticky_po_q, page_offset_sticky_pa_q[11:0],
                 s1_v, s2_wr_valid, s2_entry.address[11:0], s2_entry.trans_id,
                 page_offset_matches_now, po_commit_match, po_spec_match,
                 page_offset_matches_o, page_offset_spec_only_o,
                 spec_stall_futile, load_paddr_valid_i, page_offset_i,
                 load_paddr_i[11:0], commit_i, commit_trans_id_i,
                 commit_ready_o, no_st_pending_o, drain_no_st_pending,
                 store_buffer_empty_o, dcache_wbuffer_empty_i, flush_i,
                 valid_i, valid_without_flush_i, paddr_i[11:0], trans_id_i);
        stq_sig_q = stq_sig;
      end
    end
  end
//pragma translate_on

endmodule
