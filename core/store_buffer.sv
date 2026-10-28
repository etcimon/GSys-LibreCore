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


module store_buffer
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg        = config_pkg::cva6_cfg_empty,
    parameter type                   dcache_req_i_t = logic,
    parameter type                   dcache_req_o_t = logic,
    parameter type                   cbo_t          = logic
) (
    input logic clk_i,  // Clock
    input logic rst_ni,  // Asynchronous reset active low
    input logic flush_i,  // full flush: drop all speculative stores
    // FSE S4: younger-only cancel (SB cancelled TIDs); does not touch commit queue
    input logic [CVA6Cfg.NR_SB_ENTRIES-1:0] cancelled_mask_i,
    // Scoreboard issued mask: an OoO speculative entry is a reservation whose
    // scoreboard slot must still be live (assertion only)
    input logic [CVA6Cfg.NR_SB_ENTRIES-1:0] sb_live_i,
    input logic stall_st_pending_i,  // Stall issuing non-speculative request
    output logic         no_st_pending_o, // non-speculative queue is empty (e.g.: everything is committed to the memory hierarchy)
    output logic         store_buffer_empty_o, // there is no store pending in neither the speculative unit or the non-speculative queue

    input  logic [11:0]  page_offset_i,         // load VA/PA[11:0] (always available)
    // R3a: full load paddr when DTLB has translated; required for exact STQ match.
    input  logic [CVA6Cfg.PLEN-1:0] load_paddr_i,
    input  logic                    load_paddr_valid_i,
    // U5.4 OoO program-order keys. A store may only be observed by a load that
    // follows it in program order, and stores must reach memory in that order.
    // Index order is not age once scoreboard slots are reused, so age is the
    // circular trans_id distance from the oldest live instruction. Both inputs
    // are inert when OoOEn is 0.
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0] load_trans_id_i,
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0] commit_trans_id_i,
    // T6b-4b: the scoreboard reclaim pointer — the oldest live slot. This is
    // the program-age anchor for the speculative queue's circular ordering;
    // commit_trans_id_i stays the *committing* tid (port-0 slot) for the
    // head-match gate below. Aliases commit_trans_id_i under legacy order.
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0] oldest_live_tid_i,
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
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] load_hart_i,
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
    // R3a: store→load data forward (byte-merge, oldest→youngest). When a load's
    // BE is fully covered, the load unit may complete without a D$ request.
    output logic                              st_fwd_valid_o,
    output logic [CVA6Cfg.XLEN-1:0]           st_fwd_data_o,
    output logic [(CVA6Cfg.XLEN/8)-1:0]       st_fwd_be_o,

    input logic commit_i,  // commit the instruction which was placed there most recently
    output logic commit_ready_o,  // commit queue is ready to accept another commit request
    output logic ready_o,  // the store queue is ready to accept a new request
                           // it is only ready if it can unconditionally commit the instruction, e.g.:
                           // the commit buffer needs to be empty
    input logic valid_i,  // this is a valid store
    input  logic         valid_without_flush_i, // just tell if the address is valid which we are current putting and do not take any further action

    input  logic [CVA6Cfg.PLEN-1:0]  paddr_i,         // physical address of store which needs to be placed in the queue
    input  logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id_i, // scoreboard tid (FSE S4 younger cancel)
    // T6b: hart of the arriving store, recorded on its speculative entry.
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] st_hart_i,
    output logic [CVA6Cfg.PLEN-1:0] rvfi_mem_paddr_o,
    input logic [CVA6Cfg.XLEN-1:0] data_i,  // data which is placed in the queue
    input logic [(CVA6Cfg.XLEN/8)-1:0] be_i,  // byte enable in
    input logic [1:0] data_size_i,  // type of request we are making (e.g.: bytes to write)
    input cbo_t cbo_op_i,  // type of cache block operation

    // D$ interface
    input  dcache_req_o_t req_port_i,
    output dcache_req_i_t req_port_o
);

  // FSE S1: speculative/commit queue depths.
  // DeepSpecEn=0 → legacy ariane_pkg::DEPTH_SPEC/COMMIT (4) for netlist identity.
  // DeepSpecEn=1 → next power-of-two of MaxOutstandingStores (capped 16).
  function automatic int unsigned fse_next_pow2(input int unsigned n);
    if (n <= 1) return 1;
    if (n <= 2) return 2;
    if (n <= 4) return 4;
    if (n <= 8) return 8;
    if (n <= 16) return 16;
    return 32;
  endfunction
  localparam int unsigned DEPTH_SPEC = CVA6Cfg.DeepSpecEn
      ? fse_next_pow2(
            (CVA6Cfg.MaxOutstandingStores < 4) ? 4 :
            (CVA6Cfg.MaxOutstandingStores > 16) ? 16 : CVA6Cfg.MaxOutstandingStores)
      : int'(ariane_pkg::DEPTH_SPEC);
  localparam int unsigned DEPTH_COMMIT = CVA6Cfg.DeepSpecEn
      ? fse_next_pow2(
            (CVA6Cfg.MaxOutstandingStores < 4) ? 4 :
            (CVA6Cfg.MaxOutstandingStores > 8) ? 8 : CVA6Cfg.MaxOutstandingStores)
      : int'(ariane_pkg::DEPTH_COMMIT);

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
      (CVA6Cfg.DCACHE_LINE_WIDTH >= 64) ? (CVA6Cfg.DCACHE_LINE_WIDTH / 8) : 64;
`else
  localparam int unsigned CBOZ_LINE_B = config_pkg::CBO_BLOCK_BYTES;
`endif
  localparam int unsigned CBOZ_STRIDE = CVA6Cfg.XLEN / 8;
  localparam int unsigned CBOZ_BEATS =
      (CBOZ_LINE_B / CBOZ_STRIDE) > 0 ? (CBOZ_LINE_B / CBOZ_STRIDE) : 1;
  localparam int unsigned CBOZ_BEAT_W = (CBOZ_BEATS <= 1) ? 1 : $clog2(CBOZ_BEATS);
  // Line-offset width: also the granularity of the [11:0] hazard match below
  // (a cbo.zero line can never cross a 4 KiB page for any sane line size).
  localparam int unsigned CBOZ_OFF_W = $clog2(CBOZ_LINE_B);

  logic [CBOZ_BEAT_W-1:0] cboz_beat_q, cboz_beat_n;

  localparam int unsigned HID_W = $clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2);
  // T6b: speculative forwarding is same-hart only when two OoO harts can be
  // resident. The committed queue is NOT filtered — a committed store is
  // architectural and visible to every hart.
`ifdef G6LC_MUT_STB_NO_HART
  // Review-only mutation: speculative forwarding ignores the hart tag — a
  // peer hart's in-flight store can feed this hart's loads.
  localparam bit HART_OWN = 1'b0;
`else
  localparam bit HART_OWN = CVA6Cfg.OoOEn && CVA6Cfg.NrHarts > 1;
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
  struct packed {
    logic [CVA6Cfg.PLEN-1:0] address;
    logic [CVA6Cfg.XLEN-1:0] data;
    logic [(CVA6Cfg.XLEN/8)-1:0] be;
    logic [1:0] data_size;
    cbo_t cbo_op;
    logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id;  // FSE S4: for younger-only cancel
    logic [HID_W-1:0] hart;  // T6b: owning hart (speculative queue only)
    logic valid;  // this entry is valid, we need this for checking if the address offset matches
    logic wait_rvalid;  // need to wait for rvalid...
    // G1ah: this spec entry already forwarded to a load. SMT+SS flush/cancel
    // must not drop it (0x68 saw 0x2c8; epi ld retired P5 0x14c).
    logic fwd_keep;
  }
      speculative_queue_n[DEPTH_SPEC-1:0],
      speculative_queue_q[DEPTH_SPEC-1:0],
      commit_queue_n[DEPTH_COMMIT-1:0],
      commit_queue_q[DEPTH_COMMIT-1:0];

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

  localparam bit LEGACY_SMT_KEEP = CVA6Cfg.SuperscalarEn && CVA6Cfg.NrHarts > 1 && !CVA6Cfg.OoOEn;

  // Program order under OoO: circular trans_id distance from the oldest live
  // instruction, the same key g6lc_lsq.sv applies with commit_ptr_i. Declared
  // ahead of first use: Verilator tolerates a later declaration, slang does not.
  function automatic logic ooo_older(input logic [CVA6Cfg.TRANS_ID_BITS-1:0] a,
                                     input logic [CVA6Cfg.TRANS_ID_BITS-1:0] b);
    // T6b-4b: age distances are anchored at the reclaim pointer (oldest live
    // slot), not the port-0 commit slot — under per-hart commit heads they
    // can diverge.
    return g6lc_ooo_pkg::ooo_age_older(CVA6Cfg.TRANS_ID_BITS, 32'(a), 32'(b), 32'(oldest_live_tid_i));
  endfunction

  // Visibility of a *speculative* store to the querying load. Commit-queue
  // entries are deliberately NOT filtered by this: they are architecturally
  // older by construction, and their trans_ids may already have been recycled
  // by younger instructions, so an age test there would reject valid data.
  function automatic logic spec_visible(input logic [CVA6Cfg.TRANS_ID_BITS-1:0] sid);
    return !CVA6Cfg.OoOEn || ooo_older(sid, load_trans_id_i);
  endfunction

  // T6b-4b: under mixed-resident OoO commit, a store may only commit when it
  // is the speculative-queue head — the queue is program-age ordered, so an
  // out-of-ring-order peer-hart commit of a younger store must not evict the
  // uncommitted head to memory. The mismatch stalls the store at the commit
  // port; tid-keyed eviction is T6b-4b' if the stall stat is material.
  localparam bit MixCommit = CVA6Cfg.OoOEn &&
                            (CVA6Cfg.NrHarts > 1) && !CVA6Cfg.SmtDrainedHandoff;
  logic spec_head_valid, spec_head_mismatch;
  // lowest set bit as a log-depth prefix OR (A140: `x & (~x+1)` maps as a carry chain)
  function automatic logic [DEPTH_SPEC-1:0] spec_lowest_set(input logic [DEPTH_SPEC-1:0] x);
    logic [DEPTH_SPEC-1:0] below;
    below = x << 1;
    for (int unsigned l = 1; l < DEPTH_SPEC; l = l << 1) below = below | (below << l);
    return x & ~below;
  endfunction
  // the head: live, and no live entry is older
  always_comb begin
    for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
      automatic logic any_older;
      any_older = 1'b0;
      for (int unsigned j = 0; j < DEPTH_SPEC; j++)
        any_older |= spec_valid_q[j] && spec_older_q[j][i];
      spec_head_oh[i] = spec_valid_q[i] && !any_older;
    end
  end
  // one-hot gather of the head entry (AND-OR over the slots)
  typedef struct packed {
    logic [CVA6Cfg.PLEN-1:0] address;
    logic [CVA6Cfg.XLEN-1:0] data;
    logic [(CVA6Cfg.XLEN/8)-1:0] be;
    logic [1:0] data_size;
    cbo_t cbo_op;
    logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id;
    logic [HID_W-1:0] hart;
    logic valid;
    logic wait_rvalid;
    logic fwd_keep;
  } spec_entry_t;
  spec_entry_t spec_head;
  always_comb begin
    spec_head = '0;
    for (int unsigned i = 0; i < DEPTH_SPEC; i++)
      if (spec_head_oh[i]) spec_head = spec_head | spec_entry_t'(speculative_queue_q[i]);
  end
  assign spec_head_valid = |spec_head_oh;
  assign spec_head_mismatch = MixCommit && spec_head_valid &&
                              (spec_head.trans_id != commit_trans_id_i);
  // debug aliases of the retired ring pointers (census, leaf benches)
  always_comb begin
    speculative_read_pointer_q  = '0;
    speculative_write_pointer_q = '0;
    for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
      if (spec_head_oh[i]) speculative_read_pointer_q  = speculative_read_pointer_q  | $clog2(DEPTH_SPEC)'(i);
      if (spec_ins_oh[i])  speculative_write_pointer_q = speculative_write_pointer_q | $clog2(DEPTH_SPEC)'(i);
    end
  end

  assign store_buffer_empty_o = (speculative_status_cnt_q == 0) & no_st_pending_o;
  // ----------------------------------------
  // Speculative Queue - Core Interface
  // ----------------------------------------
  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin store_buffer status=proposal target=10-adjusted-FO4
  // svt-plan: landed A141 — the reshape facet: stationary slots, an age
  // matrix written at insertion, one-hot head and per-byte youngest-writer
  // merge; cycle-exact against the ring (4 x 400k), placed 4.159 -> 2.811 ns
  // worst / 4.159 -> 2.148 ns reg->reg at -36% area. Remaining facets below.
  // svt-plan: cone spec_rewrite combines arrival rank, survivor ranks and a
  // wide payload gather; delaying its inputs leaves that recurrence intact.
  // svt-plan: reshape keep payloads in stationary slots; update live bits
  // locally on cancel/commit and order narrow slot references, not store data.
  // svt-plan: boundary prepare bank-local age/byte candidates, then merge;
  // a pending commit descriptor owns its slot until the commit queue accepts.
  // svt-plan: carry slot+generation, TID, hart, age context, PA, data, be,
  // size, cbo_op and acceptance/commit state through every pending operation.
  // svt-plan: capacity reserve a free slot before the store-unit promise;
  // count all reservations once; acceptance is not a same-cycle valid/ready test.
  // svt-plan: visibility include pending stores in hazards/forwarding;
  // choose youngest older store PER BYTE; committed sources survive flush;
  // preserve valid_without_flush_i, CBO_ZERO coverage and handoff stickies.
  // svt-plan: conflict invalidate prepared candidates on slot reuse, kill
  // or age-context change; reselect on conflict, never install stale ranks.
  // svt-plan: effect removes DEPTH-wide payload movement from queue update;
  // local compare then balanced winner merge can replace serial forwarding.
  // svt-plan: cost metadata and pending descriptors; extra lookup/commit
  // latency needs load_unit/store_unit/commit integration; no uniform shift.
  // svt-plan: limit age selection, free-slot allocation and byte merges
  // remain; LEGACY_SMT_KEEP needs its own ownership rules before enabling.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A124/A141). The queue's next state is
  // now slot-local: a free-slot insert, a one-hot pop, per-entry cancel
  // verdicts and the age matrix; no permutation remains. A stage inside the
  // block would still split one transaction's view (insert + its age row
  // + the count), and the store request has a protocol (valid_i, trans_id_i,
  // cancelled_mask_i, flush_i): input staging before this block is the
  // admissible mechanism, with ready_o accounting for the staged entry.
  // svt-pipe: require-contract
  // svt-pipe: protocol st valid=valid_i id=trans_id_i kill=cancelled_mask_i[$id] flush=flush_i
  // svt-pipe: no-cut on=speculative_queue_n
  // svt-pipe: no-cut on=spec_older_n
  // svt-pipe: cycle st q=speculative_queue_n d=spec_older_n hold=valid_i steps=1
  // svt-pipe: cut-ok st on=spec_older_n
  // No payload register: the queue next-state is combinational with valid_i.
  always_comb begin : core_if
    automatic logic ins_active, lgcy_flush_keep;
    automatic logic [DEPTH_SPEC-1:0] cancel_hit, live_after;
    automatic logic [DEPTH_SPEC-1:0] arrival_older_than;  // entry j is older than the arrival
    automatic logic [$clog2(DEPTH_SPEC):0] cnt;
    speculative_queue_n = speculative_queue_q;
    spec_older_n        = spec_older_q;
    // the arrival takes the lowest free slot (a slot freed this cycle is
    // taken next cycle; the capacity assertion below guarantees a free one)
    spec_ins_oh = spec_lowest_set(~spec_valid_q);
    // the head leaves on commit
    spec_pop    = commit_i ? spec_head_oh : '0;
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
    live_after = spec_valid_q & ~spec_pop & ~spec_remove;

    // LSU interface: accept a new entry (skip if this TID is already
    // cancelled — FSE S4); a flush in the same cycle drops it below exactly
    // as the ring did (the arrival was inserted, then the flush evicted all)
    ins_active = valid_i && !cancelled_mask_i[trans_id_i];
    // program age of the arrival against every entry that stays live: under
    // OoO the circular distance from the oldest live slot (U5.4), in order
    // the arrival is the youngest
    for (int unsigned j = 0; j < DEPTH_SPEC; j++)
      arrival_older_than[j] = live_after[j] &&
                              (!CVA6Cfg.OoOEn || ooo_older(speculative_queue_q[j].trans_id, trans_id_i));

    // removals first: valid off, age rows and columns cleared
    for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
      if (spec_pop[i] || spec_remove[i]) begin
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
    // the insertion: payload into the free slot, its age row and column
    if (ins_active) begin
      for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
        if (spec_ins_oh[i]) begin
          speculative_queue_n[i].address = paddr_i;
          speculative_queue_n[i].data = data_i;
          speculative_queue_n[i].be = be_i;
          speculative_queue_n[i].data_size = data_size_i;
          speculative_queue_n[i].valid = 1'b1;
          speculative_queue_n[i].cbo_op = cbo_op_i;
          speculative_queue_n[i].trans_id = trans_id_i;
          speculative_queue_n[i].hart = st_hart_i;
          speculative_queue_n[i].wait_rvalid = 1'b0;
          speculative_queue_n[i].fwd_keep =
              LEGACY_SMT_KEEP &&
              load_paddr_valid_i && pa_eq(paddr_i, load_paddr_i);
          for (int unsigned j = 0; j < DEPTH_SPEC; j++) begin
            spec_older_n[j][i] = arrival_older_than[j];
            spec_older_n[i][j] = live_after[j] && !arrival_older_than[j];
          end
        end
      end
      // a flush (non-legacy) in the arrival's cycle evicts it as well
      if (flush_i && !LEGACY_SMT_KEEP) begin
        for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
          if (spec_ins_oh[i]) begin
            speculative_queue_n[i].valid = 1'b0;
            for (int unsigned j = 0; j < DEPTH_SPEC; j++) begin
              spec_older_n[i][j] = 1'b0;
              spec_older_n[j][i] = 1'b0;
            end
          end
        end
      end
    end

    // occupancy from the accepted events (the count is the popcount of the
    // live slots; the assertion below checks it)
    cnt = '0;
    for (int unsigned i = 0; i < DEPTH_SPEC; i++) cnt += ($clog2(DEPTH_SPEC) + 1)'(speculative_queue_n[i].valid);
    speculative_status_cnt_n = cnt;

    // we are ready if the speculative and the commit queue have a space left
    ready_o = (speculative_status_cnt_n < $bits(speculative_status_cnt_n)'(DEPTH_SPEC)) || commit_i;
  end

  // ----------------------------------------
  // Commit Queue - Memory Interface
  // ----------------------------------------

  // we will never kill a request in the store buffer since we already know that the translation is valid
  // e.g.: a kill request will only be necessary if we are not sure if the requested memory address will result in a TLB fault
  assign req_port_o.kill_req = 1'b0;
  assign req_port_o.data_we = 1'b1;  // we will always write in the store queue
  assign req_port_o.tag_valid = 1'b0;

  // we do not require an acknowledgement for writes, thus we do not need to identify uniquely the responses
  assign req_port_o.data_id = '0;
  // those signals can directly be output to the memory
  // (cboz_beat_q is 0 for any non-CBO_ZERO head — it is only ever advanced
  // while a CBO_ZERO entry sits at the commit head and cleared on retire)
  assign req_port_o.address_index =
      commit_queue_q[commit_read_pointer_q].address[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0] +
      CVA6Cfg.DCACHE_INDEX_WIDTH'(cboz_beat_q * CBOZ_STRIDE);
  // if we got a new request we already saved the tag from the previous cycle
  assign req_port_o.address_tag   = commit_queue_q[commit_read_pointer_q].address[CVA6Cfg.DCACHE_TAG_WIDTH     +
                                                                                    CVA6Cfg.DCACHE_INDEX_WIDTH-1 :
                                                                                    CVA6Cfg.DCACHE_INDEX_WIDTH];
  assign req_port_o.data_wdata = commit_queue_q[commit_read_pointer_q].data;
  assign req_port_o.data_wuser = '0;
  assign req_port_o.data_be = commit_queue_q[commit_read_pointer_q].be;
  assign req_port_o.data_size = commit_queue_q[commit_read_pointer_q].data_size;

  assign rvfi_mem_paddr_o = spec_head.address;

  always_comb begin : store_if
    automatic logic [$clog2(DEPTH_COMMIT):0] commit_status_cnt;
    commit_status_cnt      = commit_status_cnt_q;

    commit_ready_o         = (commit_status_cnt_q < $bits(commit_status_cnt_q)'(DEPTH_COMMIT)) &&
                             !spec_head_mismatch;
    // no store is pending if we don't have any element in the commit queue e.g.: it is empty
    no_st_pending_o        = (commit_status_cnt_q == 0);
    // default assignments
    commit_read_pointer_n  = commit_read_pointer_q;
    commit_write_pointer_n = commit_write_pointer_q;
    cboz_beat_n            = cboz_beat_q;

    commit_queue_n         = commit_queue_q;

    req_port_o.data_req    = 1'b0;
    req_port_o.cbo_op      = commit_queue_q[commit_read_pointer_q].cbo_op;

    // there should be no commit when we are flushing
    // if the entry in the commit queue is valid and not speculative anymore we can issue this instruction
    if (commit_queue_q[commit_read_pointer_q].valid && !stall_st_pending_i && !commit_queue_q[commit_read_pointer_q].wait_rvalid) begin
      req_port_o.data_req = 1'b1;
      if (req_port_i.data_gnt) begin
        if (commit_queue_q[commit_read_pointer_q].cbo_op == ariane_pkg::CBO_NONE || req_port_i.data_rvalid) begin
          // not CBO or rvalid as well -> we can evict it from the commit buffer
          // check for rvalid is technically superfluous, as CBO latency is >= 1 cycle, but check it anyway just to be safe
          commit_queue_n[commit_read_pointer_q].valid = 1'b0;
          // advance the read_pointer
          commit_read_pointer_n = commit_read_pointer_q + 1'b1;
          commit_status_cnt--;
          cboz_beat_n = '0;
        end else if (commit_queue_q[commit_read_pointer_q].cbo_op != ariane_pkg::CBO_NONE) begin
          // CBO and have gotten data grant -> proceed to wait for rvalid
          commit_queue_n[commit_read_pointer_q].wait_rvalid = 1'b1;
        end
      end
    end

    if(commit_queue_q[commit_read_pointer_q].valid && commit_queue_q[commit_read_pointer_q].wait_rvalid)
    begin
      // wait for rvalid, but no need to raise another request / wait for grant
      if (req_port_i.data_rvalid) begin
        // CMO did commit — for a CBO_ZERO entry this is one beat of the
        // drain expansion: clear wait_rvalid and advance to the next beat,
        // or retire the (single) architectural entry after the last beat.
        if (CVA6Cfg.RVZiCboz &&
            commit_queue_q[commit_read_pointer_q].cbo_op == ariane_pkg::CBO_ZERO &&
            cboz_beat_q != CBOZ_BEAT_W'(CBOZ_BEATS - 1)) begin
          commit_queue_n[commit_read_pointer_q].wait_rvalid = 1'b0;
          cboz_beat_n = cboz_beat_q + 1'b1;
        end else begin
          // we can evict the entry from the commit buffer
          commit_queue_n[commit_read_pointer_q].valid = 1'b0;
          // advance the read_pointer
          commit_read_pointer_n = commit_read_pointer_q + 1'b1;
          commit_status_cnt--;
          cboz_beat_n = '0;
        end
      end
    end

    // we ignore the rvalid signal for now as we assume that the store
    // happened if we got a grant

    // shift the store request from the speculative buffer to the non-speculative
    if (commit_i) begin
      commit_queue_n[commit_write_pointer_q] = spec_head;
      commit_write_pointer_n = commit_write_pointer_n + 1'b1;
      commit_status_cnt++;
    end

    commit_status_cnt_n = commit_status_cnt;
  end

  // ------------------
  // Address Checker
  // ------------------
  // The load should return the data stored by the most recent store to the
  // same physical address.  The most direct way to implement this is to
  // maintain physical addresses in the store buffer.

  // Of course, there are other micro-architectural techniques to accomplish
  // the same thing: you can interlock and wait for the store buffer to
  // drain if the load VA matches any store VA modulo the page size (i.e.
  // bits 11:0).  As a special case, it is correct to bypass if the full VA
  // matches, and no younger stores' VAs match in bits 11:0.
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
  // R3a: hazard detect uses full paddr when available (DTLB hit). [11:0]-only
  // matching false-aliased stack SW vs FDT structure loads across pages and
  // either stalled forever or STQ-forwarded the wrong bytes (*nextoff=-11).
  logic page_offset_matches_now;
  // N1d: while the commit head is an unpublished load, every speculative
  // entry's drain waits on commit progress that itself waits on this LSU —
  // a circular wait. Suppress the speculative stall terms only: the
  // commit-queue and sticky terms drain autonomously and must still gate.
  logic spec_stall_futile;
  assign spec_stall_futile = HEAD_GATE_EN && head_phys_pending_i;
  logic [CVA6Cfg.PLEN-1:0] page_offset_sticky_pa_q;
  logic                    page_offset_sticky_v_q;
  logic                    page_offset_sticky_po_v_q;  // [11:0]-only sticky
  logic [11:0]             page_offset_sticky_po_q;
  logic                    po_commit_match, po_spec_match;
  // G1ao: last live STQ forward, replayed to the next same-PA load.
  logic                          g1ao_hold_v_q, g1ao_hold_hit;
  logic [CVA6Cfg.PLEN-1:0]       g1ao_hold_pa_q;
  logic [CVA6Cfg.XLEN-1:0]       g1ao_hold_data_q;
  logic [(CVA6Cfg.XLEN/8)-1:0]   g1ao_hold_be_q, st_fwd_live_be;

  // Paddr equality at the data-lane granularity (XLEN/8 bytes). The STQ
  // forward and the page-offset interlock below must see every store whose
  // bytes fall inside the load's lane, not only a store at the load's own
  // byte address: byte-exact matching let a doubleword load pass two
  // younger-than-nothing/older-than-the-load narrow stores at +2/+4 of its
  // lane with neither forward nor stall and read the stale line (T31,
  // ooo_mem_min stage 47; Linux printk's printf_spec bitfields on
  // g6lc64_ooo). Lanes are be-masked, so a lane match forwards exactly the
  // written bytes; a lane-crossing access is split or trapped before here.
  localparam int unsigned LANE_W = $clog2(CVA6Cfg.XLEN / 8);
  function automatic logic pa_eq(input logic [CVA6Cfg.PLEN-1:0] a,
                                 input logic [CVA6Cfg.PLEN-1:0] b);
    return a[CVA6Cfg.PLEN-1:LANE_W] == b[CVA6Cfg.PLEN-1:LANE_W];
  endfunction
  function automatic logic po_eq(input logic [11:0] a, input logic [11:0] b);
    return a[11:LANE_W] == b[11:LANE_W];
  endfunction

  // U7c: a cbo.zero entry's coverage is its whole cache line (the stored
  // address is the line-aligned base). Match by line tag so loads anywhere
  // in the line stall on the pending entry and forward zeros.
  function automatic logic cboz_covers(input cbo_t cop,
                                       input logic [CVA6Cfg.PLEN-1:0] entry_pa,
                                       input logic [CVA6Cfg.PLEN-1:0] byte_pa);
    return CVA6Cfg.RVZiCboz && (cop == ariane_pkg::CBO_ZERO) &&
           (entry_pa[CVA6Cfg.PLEN-1:CBOZ_OFF_W] ==
            byte_pa[CVA6Cfg.PLEN-1:CBOZ_OFF_W]);
  endfunction

  always_comb begin : address_checker
    // R3a: **stall** on [11:0] always (classic Ariane — never miss stack RAW).
    // load_paddr is vaddr (see load_unit); full-PA-only stall missed stack RAW
    // when store queue holds paddr form. Forward remains full-PA only.
    // cont.11 false-alias FDT vs stack is still open (next_tag tag=9).
    page_offset_matches_now = 1'b0;
    po_commit_match = 1'b0;
    po_spec_match   = 1'b0;

    for (int unsigned i = 0; i < DEPTH_COMMIT; i++) begin
      if (commit_queue_q[i].valid &&
          (po_eq(commit_queue_q[i].address[11:0], page_offset_i) ||
           (CVA6Cfg.RVZiCboz &&
            commit_queue_q[i].cbo_op == ariane_pkg::CBO_ZERO &&
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
           (CVA6Cfg.RVZiCboz &&
            speculative_queue_q[i].cbo_op == ariane_pkg::CBO_ZERO &&
            ((speculative_queue_q[i].address[11:0] >> CBOZ_OFF_W) ==
             (page_offset_i >> CBOZ_OFF_W))))) begin
        page_offset_matches_now = 1'b1;
        po_spec_match = 1'b1;
        break;
      end
    end
    if (!spec_stall_futile && valid_without_flush_i && spec_visible(trans_id_i) &&
        (po_eq(paddr_i[11:0], page_offset_i) ||
         (CVA6Cfg.RVZiCboz && cbo_op_i == ariane_pkg::CBO_ZERO &&
          ((paddr_i[11:0] >> CBOZ_OFF_W) == (page_offset_i >> CBOZ_OFF_W))))) begin
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

  // Forward only on full paddr match (never on [11:0] alone).
  always_comb begin : st_fwd_merge
    automatic logic [CVA6Cfg.XLEN-1:0]     data_m;
    automatic logic [(CVA6Cfg.XLEN/8)-1:0] be_m;
    automatic logic [$clog2(DEPTH_COMMIT)-1:0] cidx;
    // A141 spec_fwd temporaries, declared and defaulted at the block's top:
    // declared inside the `if (load_paddr_valid_i)` branch they were assigned
    // on one path only and Verilator inferred latches for them (12 LATCH
    // warnings on the HEAD builds); the logic is unchanged.
    automatic logic [DEPTH_SPEC-1:0] ent_match;
    automatic logic [DEPTH_SPEC-1:0][(CVA6Cfg.XLEN/8)-1:0] cand, win;
    automatic logic [DEPTH_SPEC-1:0][CVA6Cfg.XLEN-1:0] val;
    automatic logic younger_writes, any_cand;
    automatic logic [7:0] byte_v;
    data_m         = '0;
    be_m           = '0;
    cidx           = '0;
    ent_match      = '0;
    cand           = '0;
    win            = '0;
    val            = '0;
    younger_writes = 1'b0;
    any_cand       = 1'b0;
    byte_v         = '0;

    if (load_paddr_valid_i) begin
      for (int unsigned k = 0; k < DEPTH_COMMIT; k++) begin
        cidx = commit_read_pointer_q + $clog2(DEPTH_COMMIT)'(k);
        if (commit_queue_q[cidx].valid &&
            (pa_eq(commit_queue_q[cidx].address, load_paddr_i) ||
             cboz_covers(commit_queue_q[cidx].cbo_op,
                         commit_queue_q[cidx].address, load_paddr_i))) begin
          if (CVA6Cfg.RVZiCboz &&
              commit_queue_q[cidx].cbo_op == ariane_pkg::CBO_ZERO) begin
            // the entry zeroes its whole line: forward '0 for every load
            // byte inside that line (per-byte check covers straddling loads);
            // data_m must be cleared — an older store may already have
            // written nonzero bytes to this lane.
            for (int unsigned b = 0; b < (CVA6Cfg.XLEN / 8); b++) begin
              if (cboz_covers(commit_queue_q[cidx].cbo_op,
                              commit_queue_q[cidx].address,
                              load_paddr_i + CVA6Cfg.PLEN'(b))) begin
                data_m[8*b+:8] = '0;
                be_m[b]        = 1'b1;
              end
            end
          end else begin
            for (int unsigned b = 0; b < (CVA6Cfg.XLEN / 8); b++) begin
              if (commit_queue_q[cidx].be[b]) begin
                data_m[8*b+:8] = commit_queue_q[cidx].data[8*b+:8];
                be_m[b]        = 1'b1;
              end
            end
          end
        end
      end
      // A141: the speculative sources in program order without walking a
      // ring: every entry is a candidate per byte (older than the load, same
      // hart, lane or cbo.zero line match, byte written), and a byte takes
      // the candidate that no younger candidate also writes — the same
      // "last writer in program order wins" the ordered walk implemented.
      begin : spec_fwd
        for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
          ent_match[i] = speculative_queue_q[i].valid &&
                         spec_visible(speculative_queue_q[i].trans_id) &&
                         (!HART_OWN || speculative_queue_q[i].hart == load_hart_i) &&
                         (pa_eq(speculative_queue_q[i].address, load_paddr_i) ||
                          cboz_covers(speculative_queue_q[i].cbo_op,
                                      speculative_queue_q[i].address, load_paddr_i));
          for (int unsigned b = 0; b < (CVA6Cfg.XLEN / 8); b++) begin
            if (CVA6Cfg.RVZiCboz && speculative_queue_q[i].cbo_op == ariane_pkg::CBO_ZERO) begin
              cand[i][b] = ent_match[i] &&
                           cboz_covers(speculative_queue_q[i].cbo_op, speculative_queue_q[i].address,
                                       load_paddr_i + CVA6Cfg.PLEN'(b));
              val[i][8*b+:8] = '0;
            end else begin
              cand[i][b] = ent_match[i] && speculative_queue_q[i].be[b];
              val[i][8*b+:8] = speculative_queue_q[i].data[8*b+:8];
            end
          end
        end
        for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
          for (int unsigned b = 0; b < (CVA6Cfg.XLEN / 8); b++) begin
            younger_writes = 1'b0;
            for (int unsigned j = 0; j < DEPTH_SPEC; j++)
              younger_writes |= spec_older_q[i][j] && cand[j][b];
            win[i][b] = cand[i][b] && !younger_writes;
          end
        end
        for (int unsigned b = 0; b < (CVA6Cfg.XLEN / 8); b++) begin
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
      if (valid_without_flush_i && spec_visible(trans_id_i) &&
          (!HART_OWN || st_hart_i == load_hart_i) &&
          (pa_eq(paddr_i, load_paddr_i) ||
           cboz_covers(cbo_op_i, paddr_i, load_paddr_i))) begin
        if (CVA6Cfg.RVZiCboz && cbo_op_i == ariane_pkg::CBO_ZERO) begin
          for (int unsigned b = 0; b < (CVA6Cfg.XLEN / 8); b++) begin
            if (cboz_covers(cbo_op_i, paddr_i, load_paddr_i + CVA6Cfg.PLEN'(b))) begin
              data_m[8*b+:8] = '0;
              be_m[b]        = 1'b1;
            end
          end
        end else begin
          for (int unsigned b = 0; b < (CVA6Cfg.XLEN / 8); b++) begin
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
    // Soft-ladder iter-012: STQ-nofwd under SuperscalarEn was PEEL_FDT-negative
    // (fw64d, same mepc=0x12eb2 mtval=0x12b2a) — re-enabled forward.
    st_fwd_valid_o = |be_m;
  end

  // R3a cont.13: **store-side** sticky on STQ→D$ grant.
  // Load-side sticky only armed when a load was checking during STQ occupancy;
  // the caller's post-return load of libfdt *nextoffset often issues after the
  // store left the STQ, so match_now was never seen and sticky never set.
  // Capture the store address when it is granted into the D$ wbuffer and hold
  // until wbuffer_empty so load_unit condition (2) covers the handoff.
  logic st_to_wbuf_grant;
  assign st_to_wbuf_grant =
      commit_queue_q[commit_read_pointer_q].valid && !stall_st_pending_i &&
      !commit_queue_q[commit_read_pointer_q].wait_rvalid && req_port_i.data_gnt &&
      (commit_queue_q[commit_read_pointer_q].cbo_op == ariane_pkg::CBO_NONE ||
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
  for (genvar i = 0; i < DEPTH_SPEC; i++) begin : gen_spec_valid
    assign spec_valid_q[i] = speculative_queue_q[i].valid;
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
  bit smt_store_trace, smt_store_watch;
  logic [CVA6Cfg.PLEN-1:0] smt_store_address;
  int unsigned smt_store_cycle = 0;
  initial begin
    smt_store_watch = $value$plusargs("smt_mem_watch=%h", smt_store_address);
    smt_store_trace = $test$plusargs("smt_flow_trace") || smt_store_watch;
  end
  always @(posedge clk_i) begin
    if (!rst_ni) smt_store_cycle = 0;
    else if (smt_store_trace) begin
      smt_store_cycle++;
      if (valid_i && (!smt_store_watch || pa_eq(paddr_i, smt_store_address)))
        $display("[smt-flow] store_offer cycle=%0d id=%0d pa=%h data=%h be=%h cancel=%b flush=%b ready=%b",
                 smt_store_cycle, trans_id_i, paddr_i, data_i, be_i,
                 cancelled_mask_i[trans_id_i], flush_i, ready_o);
      if (commit_i && (!smt_store_watch || pa_eq(speculative_queue_q[speculative_read_pointer_q].address, smt_store_address)))
        $display("[smt-flow] store_commit cycle=%0d id=%0d pa=%h data=%h be=%h valid=%b",
                 smt_store_cycle, speculative_queue_q[speculative_read_pointer_q].trans_id,
                 speculative_queue_q[speculative_read_pointer_q].address,
                 speculative_queue_q[speculative_read_pointer_q].data,
                 speculative_queue_q[speculative_read_pointer_q].be,
                 speculative_queue_q[speculative_read_pointer_q].valid);
      if (req_port_o.data_req && req_port_i.data_gnt &&
          (!smt_store_watch || pa_eq(commit_queue_q[commit_read_pointer_q].address, smt_store_address)))
        $display("[smt-flow] store_drain cycle=%0d id=%0d pa=%h data=%h be=%h",
                 smt_store_cycle, commit_queue_q[commit_read_pointer_q].trans_id,
                 commit_queue_q[commit_read_pointer_q].address, req_port_o.data_wdata,
                 req_port_o.data_be);
      if (load_paddr_valid_i && (!smt_store_watch || pa_eq(load_paddr_i, smt_store_address)))
        $display("[smt-flow] store_forward cycle=%0d pa=%h valid=%b data=%h be=%h replay=%b",
                 smt_store_cycle, load_paddr_i, st_fwd_valid_o, st_fwd_data_o, st_fwd_be_o, g1ao_hold_hit);
    end
  end
  // Witness for the forwarding age contract (T21e rewrite): every byte the
  // load takes must have a VISIBLE source -- a commit-queue entry (older by
  // construction), a speculative entry older than the load (spec_visible),
  // or the arriving store when it is older. The previous form flagged the
  // mere presence of a younger same-address entry in the queue while the load
  // forwarded from an older one -- a legal OoO state (an older load held on a
  // write-path stall while the next loop iteration's store to the same word
  // arrived; sbi_heap_init on the server) and the merge above never read that
  // entry, so it was a false positive. This form fails only if a byte is
  // forwarded with no older source behind it, i.e. if the merge ever stopped
  // applying the age filter.
  logic [(CVA6Cfg.XLEN/8)-1:0] ooo_fwd_visible_cover;
  logic ooo_fwd_without_visible_source;
  always_comb begin
    ooo_fwd_visible_cover = '0;
    ooo_fwd_without_visible_source = 1'b0;
    if (CVA6Cfg.OoOEn && load_paddr_valid_i && st_fwd_valid_o) begin
      for (int unsigned i = 0; i < DEPTH_COMMIT; i++)
        if (commit_queue_q[i].valid)
          for (int unsigned b = 0; b < (CVA6Cfg.XLEN / 8); b++)
            if ((pa_eq(commit_queue_q[i].address, load_paddr_i) && commit_queue_q[i].be[b]) ||
                (CVA6Cfg.RVZiCboz && cboz_covers(commit_queue_q[i].cbo_op, commit_queue_q[i].address,
                                                 load_paddr_i + CVA6Cfg.PLEN'(b))))
              ooo_fwd_visible_cover[b] = 1'b1;
      for (int unsigned i = 0; i < DEPTH_SPEC; i++)
        if (speculative_queue_q[i].valid && spec_visible(speculative_queue_q[i].trans_id) &&
            (!HART_OWN || speculative_queue_q[i].hart == load_hart_i))
          for (int unsigned b = 0; b < (CVA6Cfg.XLEN / 8); b++)
            if ((pa_eq(speculative_queue_q[i].address, load_paddr_i) && speculative_queue_q[i].be[b]) ||
                (CVA6Cfg.RVZiCboz && cboz_covers(speculative_queue_q[i].cbo_op, speculative_queue_q[i].address,
                                                 load_paddr_i + CVA6Cfg.PLEN'(b))))
              ooo_fwd_visible_cover[b] = 1'b1;
      if (valid_without_flush_i && spec_visible(trans_id_i) && (!HART_OWN || st_hart_i == load_hart_i))
        for (int unsigned b = 0; b < (CVA6Cfg.XLEN / 8); b++)
          if ((pa_eq(paddr_i, load_paddr_i) && be_i[b]) ||
              (CVA6Cfg.RVZiCboz && cboz_covers(cbo_op_i, paddr_i, load_paddr_i + CVA6Cfg.PLEN'(b))))
            ooo_fwd_visible_cover[b] = 1'b1;
      ooo_fwd_without_visible_source = |(st_fwd_be_o & ~ooo_fwd_visible_cover);
    end
  end

  // assert that commit is never set when we are flushing this would be counter intuitive
  // as flush and commit is decided in the same stage
  commit_and_flush :
  assert property (@(posedge clk_i) rst_ni && flush_i |-> !commit_i)
  else $error("[Commit Queue] You are trying to commit and flush in the same cycle");

  speculative_buffer_overflow :
  assert property (@(posedge clk_i) rst_ni && (speculative_status_cnt_q == $bits(speculative_status_cnt_q)'(DEPTH_SPEC)) |-> !valid_i)
  else
    $error("[Speculative Queue] You are trying to push new data although the buffer is not ready");

  speculative_buffer_underflow :
  assert property (@(posedge clk_i) rst_ni && (speculative_status_cnt_q == 0) |-> !commit_i)
  else $error("[Speculative Queue] You are committing although there are no stores to commit");

  commit_buffer_overflow :
  assert property (@(posedge clk_i) rst_ni && (commit_status_cnt_q == $bits(commit_status_cnt_q)'(DEPTH_COMMIT)) |-> !commit_i)
  else $error("[Commit Queue] You are trying to commit a store although the buffer is full");

  // U5.4 OoO: the store handed to memory must be the one commit is retiring.
  // Commit is in program order, so the committing store is the oldest live
  // store and therefore the queue head. This catches any program-order
  // insertion error directly, at the handoff rather than in a later value.
  ooo_commit_is_oldest :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
                   (CVA6Cfg.OoOEn && commit_i) |->
                   (spec_head_valid && spec_head.trans_id == commit_trans_id_i))
  else
    $error("[Speculative Queue] OoO commit handoff took tid %0d, commit is retiring tid %0d",
           spec_head.trans_id, commit_trans_id_i);

  // U5.4 OoO: a store younger than the querying load must never reach it --
  // every forwarded byte has an older (visible) source.
  ooo_no_younger_forward :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
                   (CVA6Cfg.OoOEn && load_paddr_valid_i && st_fwd_valid_o) |->
                   !ooo_fwd_without_visible_source)
  else $error("[Speculative Queue] OoO load tid %0d forwarded bytes %b with no older source (visible cover %b)",
              load_trans_id_i, st_fwd_be_o, ooo_fwd_visible_cover);

  // OoO reservation liveness: every valid speculative-queue entry names a
  // scoreboard slot that is still issued/live. A reservation outliving its
  // slot (or never backed by one) means the hold-to-commit credit accounting
  // leaked.
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
  if (CVA6Cfg.OoOEn) begin : gen_spec_order_anchor
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

  if (CVA6Cfg.OoOEn) begin : gen_sb_live_assert
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
                    commit_queue_q[commit_read_pointer_q].cbo_op == ariane_pkg::CBO_ZERO))
  else $error("[Commit Queue] cbo.zero beat counter advanced without a CBO_ZERO head");

  cboz_entry_line_aligned :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
                   (CVA6Cfg.RVZiCboz && commit_i &&
                    speculative_queue_q[speculative_read_pointer_q].valid &&
                    speculative_queue_q[speculative_read_pointer_q].cbo_op ==
                    ariane_pkg::CBO_ZERO) |->
                   (speculative_queue_q[speculative_read_pointer_q].address[CBOZ_OFF_W-1:0] ==
                    '0))
  else $error("[Commit Queue] cbo.zero commit entry is not line-aligned");
  //pragma translate_on
  //pragma translate_off
  // T35 instrument (+stq_trace, window +stq_lo/+stq_hi in cycles since reset):
  // speculative-queue pushes, commits, cancels, flushes, and every valid
  // entry whose scoreboard slot is no longer live (the ooo_spec_entry_live
  // condition), so the cycle the reservation leaks is visible with its cause.
  bit stq_trace;
  longint unsigned stq_lo, stq_hi, stq_cyc;
  initial begin
    stq_trace = $test$plusargs("stq_trace");
    stq_lo = 0;
    stq_hi = 64'hFFFF_FFFF_FFFF_FFFF;
    void'($value$plusargs("stq_lo=%d", stq_lo));
    void'($value$plusargs("stq_hi=%d", stq_hi));
  end
  always @(posedge clk_i) begin
    if (!rst_ni) stq_cyc = 0;
    else stq_cyc = stq_cyc + 1;
    if (stq_trace && rst_ni && stq_cyc >= stq_lo && stq_cyc <= stq_hi) begin
      if (valid_i || valid_without_flush_i)
        $display("[stq] c=%0d PUSH v=%b vwf=%b tid=%0d hart=%0d pa=%h canc=%b flush=%b ready=%b scnt=%0d ccnt=%0d",
                 stq_cyc, valid_i, valid_without_flush_i, trans_id_i, st_hart_i, paddr_i,
                 cancelled_mask_i[trans_id_i], flush_i, ready_o,
                 speculative_status_cnt_q, commit_status_cnt_q);
      if (commit_i)
        $display("[stq] c=%0d COMMIT tid=%0d hart=%0d ready=%b", stq_cyc,
                 speculative_queue_q[speculative_read_pointer_q].trans_id,
                 speculative_queue_q[speculative_read_pointer_q].hart, commit_ready_o);
      if (|cancelled_mask_i)
        $display("[stq] c=%0d CANCEL mask=%h flush=%b", stq_cyc, cancelled_mask_i, flush_i);
      if (flush_i)
        $display("[stq] c=%0d FLUSH scnt=%0d", stq_cyc, speculative_status_cnt_q);
      for (int unsigned i = 0; i < DEPTH_SPEC; i++)
        if (speculative_queue_q[i].valid && !sb_live_i[speculative_queue_q[i].trans_id])
          $display("[stq] c=%0d DEAD entry=%0d tid=%0d hart=%0d pa=%h fk=%b", stq_cyc, i,
                   speculative_queue_q[i].trans_id, speculative_queue_q[i].hart,
                   speculative_queue_q[i].address, speculative_queue_q[i].fwd_keep);
    end
  end
  //pragma translate_on

endmodule
