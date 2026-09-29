// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.0 memory-side L2 cache — AXI slave (core) ↔ AXI master (memory).
//
// Contention-oriented features:
//   * Multi-MSHR with line-merge (no duplicate fills for same line)
//   * Banked data array (hit || fill in parallel when banks differ)
//   * Combinational non-cacheable bypass (MMIO never enters tags)
//   * Exclusive AR (AxLOCK) bypasses and forwards lock to the DRAM monitor
//   * Write-through + read-allocate (matches WT L1)
//   * Parallel SET_ASSOC tag compare
//
// When Enable=0 the module is not instantiated (caller wires AXI identity).
// Line size must equal L1 / Zic64b (64 B default). That 64 B line is also the
// default DRAM stripe (`DramChanShift=6`); a fill must not straddle a channel.

module g6lc_l2_top
  import g6lc_l2_pkg::*;
#(
    parameter bit          Enable      = 1'b1,
    parameter int unsigned BYTE_SIZE   = L2_DEFAULT_BYTE_SIZE,
    parameter int unsigned SET_ASSOC   = L2_DEFAULT_SET_ASSOC,
    parameter int unsigned LINE_WIDTH  = L2_DEFAULT_LINE_WIDTH,
    parameter int unsigned MSHR_DEPTH  = L2_DEFAULT_MSHR_DEPTH,
    parameter int unsigned DATA_BANKS  = L2_DEFAULT_DATA_BANKS,
    // Optional per-set round-robin victim select. 0 = legacy policy
    // (invalid-first, else way 0). 1 = invalid-first still wins; among
    // all-valid sets the victim is a per-set pointer advanced past the
    // last-installed way. Default-off: RR_EN=0 folds to the legacy netlist.
    parameter bit          RR_EN       = 1'b0,
    parameter bit          FAIR_WRITES = 1'b0,
    // Tag storage: 0 = flop array with a single-cycle combinational compare
    // (legacy netlist, bit-identical); 1 = tags behind a 1R1W tc_sram with a
    // launched read (see g6lc_l2_tag.tech-spec.md). The FSM launches the row
    // on every transition into (or hold of) S_TAG, so the compare still
    // completes on the first S_TAG cycle; only an inval-match port steal or
    // a missed launch holds S_TAG one extra cycle.
    parameter bit          TAG_SRAM    = 1'b0,
    // Write-update: a write-through AW that hits a resident line merges its W
    // beats into the line instead of self-invalidating the tag (measured
    // mc_l2_write_read: ~6,060 purges of resident lines per 8,192 stores and
    // ~90k of ~100k boot L2 misses followed a purge — T8e). Under 0 the
    // decision registers, merge port write and suppression logic fold away
    // and the netlist is identical to the invalidate path.
    parameter bit          WRITE_UPDATE = 1'b0,
    // Posted writes + bypass-read tracking (T9b; ordering rules 1-6 in
    // architecture/l2-l3-cache/ewt-caching.md). Every accepted write holds a
    // write-tracker entry (WTRK_DEPTH); a postable write (atop=='0, no lock,
    // id != FILL_ID) returns to S_IDLE after its last W beat and the tracker
    // forwards its memory B to the slave when it arrives. NC/lock bypass
    // reads likewise park a read-tracker entry (RDTRK_DEPTH) instead of
    // holding the FSM in S_BYPASS_R. Under 0 the trackers and the R/B
    // routing fold away and the netlist is the blocking AW/W/B path.
    parameter bit          POSTED_WRITES = 1'b0,
    parameter int unsigned WTRK_DEPTH    = 4,
    parameter int unsigned RDTRK_DEPTH   = 4,
    // T9d/M1d: set when the upstream agent may itself re-tag its posted
    // writes onto the reserved WR_ID — the inner engine of an L3 stack,
    // whose L2 forwards posted writes downstream on WR_ID. At the outer
    // (hub-facing) L2 a postable slave write arriving on WR_ID is an
    // integration violation and fails the simulation assert below; ATOP /
    // lock writes on WR_ID stay legal (they keep their original id on the
    // blocking path). Has no netlist effect — assertion gating only.
    parameter bit          SLV_WRID_OK   = 1'b0,
    // T9h/M5 stream/stride prefetcher (tier R): trained on committed demand
    // misses, next-line + fixed-stride detection, at most one prefetched
    // line in flight as a PF-flagged MSHR fill that never takes the last
    // PF_MSHR_RESERVE MSHR entries and never displaces a resident line.
    parameter bit          PF_EN          = 1'b0,
    parameter int unsigned PF_STREAMS     = 4,
    parameter int unsigned PF_DISTANCE    = 2,
    parameter bit          PF_STRIDE      = 1'b1,
    parameter int unsigned PF_MSHR_RESERVE= 1,
    parameter int unsigned AXI_ADDR_WIDTH = 64,
    parameter int unsigned AXI_DATA_WIDTH = 64,
    parameter int unsigned AXI_ID_WIDTH   = 4,
    parameter int unsigned AXI_USER_WIDTH = 1,
    // AXI channel types (inject from SoC)
    parameter type axi_req_t  = logic,
    parameter type axi_resp_t = logic
) (
    input  logic     clk_i,
    input  logic     rst_ni,
    // Toward core (L2 is slave)
    input  axi_req_t  slv_req_i,
    output axi_resp_t slv_resp_o,
    // Toward memory (L2 is master)
    output axi_req_t  mst_req_o,
    input  axi_resp_t mst_resp_i,
    // Observability
    output logic      l2_hit_o,
    output logic      l2_miss_o,
    output logic      l2_bypass_o,
    output logic      l2_mshr_full_o,
    output logic      l2_bank_conflict_o,
    // Observability pulse: an inval-match (WT write self-inval or L3
    // back-inval) actually cleared a live line this cycle. The cluster
    // leaves it unconnected; the TB counts it hierarchically as l2_selfinv.
    output logic      l2_selfinv_hit_o,
    // Observability pulse (WRITE_UPDATE): a forwarded write merged into a
    // resident line instead of purging it — one pulse per such write. The
    // cluster leaves it unconnected; the TB counts it as l2_wupd.
    output logic      l2_wupdate_o,
    // Observability pulses (T9h/M5 prefetcher): a candidate allocated an
    // MSHR fill, a demand hit to a PF-installed line, a candidate dropped
    // by admission (resident / in-flight / tracked write / MSHR reserve /
    // no free way).
    output logic      l2_pf_issue_o,
    output logic      l2_pf_useful_o,
    output logic      l2_pf_drop_o,
    // Observability pulses (POSTED_WRITES): an AW held for a full write
    // tracker, an R1/R2 line-match hold cycle, a posted write completing its
    // B on the slave channel, and a tracked bypass read draining its last
    // beat. l2_posted_hold_o is the hold-cycle union fanned into the PMU
    // group-2 "posted-write hold" event at each level.
    output logic      l2_wtrk_full_o,
    output logic      l2_wtrk_line_hold_o,
    // T9c/M1c hold-cycle split of l2_wtrk_line_hold_o: l2_hold_r1_o counts a
    // cacheable read-miss hold behind a live tracker entry (R1),
    // l2_hold_r2_o a different-id same-line AW hold (R2). The ATOP-load
    // guard stays in the aggregate only. l2_hold_r1_wu_o is the R1 subset
    // whose blocking entry was marked write-update-hit rather than
    // write-around (see g6lc_l2_wtrk mark_i/line0_wu_o).
    output logic      l2_hold_r1_o,
    output logic      l2_hold_r1_wu_o,
    output logic      l2_hold_r2_o,
    output logic      l2_posted_o,
    output logic      l2_rdtrk_o,
    output logic      l2_posted_hold_o,
    // Victim replace (valid way overwritten on miss) — inclusive LLC back-inval.
    // evict is a valid/ready offer: it re-asserts every cycle the FSM holds in
    // S_TAG, and the victim commit waits for l2_evict_ready_i, so a victim can
    // never be displaced while its back-invalidation is still unaccepted.
    // Tie ready high when no inclusive engine is connected (legacy behaviour).
    output logic                          l2_evict_valid_o,
    output logic [AXI_ADDR_WIDTH-1:0]     l2_evict_addr_o,
    input  logic                          l2_evict_ready_i,
    // L3→L2 inclusive back-invalidate (address of victim line at L3). Always
    // ready (single-cycle tag match). Tie valid low when unused.
    input  logic                          l2_back_inval_valid_i,
    input  logic [AXI_ADDR_WIDTH-1:0]     l2_back_inval_addr_i,
    output logic                          l2_back_inval_ready_o,
    // T9a eWT CMO ordering: high when no write has been accepted and not yet
    // B-acknowledged — under POSTED_WRITES that means the write tracker is
    // empty and the FSM is not in a bypass write state. The CMO engine gates
    // clean/flush completion on this.
    output logic                          l2_write_idle_o
);

  // Identity when disabled (should not be instantiated; safety net)
  if (!Enable) begin : gen_identity
    assign mst_req_o  = slv_req_i;
    assign slv_resp_o = mst_resp_i;
    assign l2_hit_o = 1'b0;
    assign l2_miss_o = 1'b0;
    assign l2_bypass_o = 1'b1;
    assign l2_mshr_full_o = 1'b0;
    assign l2_bank_conflict_o = 1'b0;
    assign l2_selfinv_hit_o = 1'b0;
    assign l2_wupdate_o = 1'b0;
    assign l2_wtrk_full_o = 1'b0;
    assign l2_wtrk_line_hold_o = 1'b0;
    assign l2_hold_r1_o = 1'b0;
    assign l2_hold_r1_wu_o = 1'b0;
    assign l2_hold_r2_o = 1'b0;
    assign l2_posted_o = 1'b0;
    assign l2_rdtrk_o = 1'b0;
    assign l2_posted_hold_o = 1'b0;
    assign l2_pf_issue_o = 1'b0;
    assign l2_pf_useful_o = 1'b0;
    assign l2_pf_drop_o = 1'b0;
    assign l2_evict_valid_o = 1'b0;
    assign l2_evict_addr_o  = '0;
    assign l2_back_inval_ready_o = 1'b1;
    assign l2_write_idle_o = 1'b1;
  end else begin : gen_l2

  localparam int unsigned LINE_BYTES  = LINE_WIDTH / 8;
  localparam int unsigned NUM_SETS    = l2_num_sets(BYTE_SIZE, SET_ASSOC, LINE_WIDTH);
  localparam int unsigned OFF_BITS    = l2_offset_bits(LINE_WIDTH);
  localparam int unsigned IDX_BITS    = l2_index_bits(NUM_SETS);
  localparam int unsigned TAG_BITS    = AXI_ADDR_WIDTH - IDX_BITS - OFF_BITS;
  localparam int unsigned BEATS       = LINE_WIDTH / AXI_DATA_WIDTH;
  localparam int unsigned WAY_W       = (SET_ASSOC <= 1) ? 1 : $clog2(SET_ASSOC);
  localparam int unsigned MSHR_W      = (MSHR_DEPTH <= 1) ? 1 : $clog2(MSHR_DEPTH);
  localparam int unsigned STRB_W      = AXI_DATA_WIDTH / 8;

  // --------------------
  // Address decode
  // --------------------
  function automatic logic [AXI_ADDR_WIDTH-1:0] line_align(input logic [AXI_ADDR_WIDTH-1:0] a);
    return {a[AXI_ADDR_WIDTH-1:OFF_BITS], {OFF_BITS{1'b0}}};
  endfunction

  function automatic logic [IDX_BITS-1:0] idx_of(input logic [AXI_ADDR_WIDTH-1:0] a);
    return a[OFF_BITS +: IDX_BITS];
  endfunction

  function automatic logic [TAG_BITS-1:0] tag_of(input logic [AXI_ADDR_WIDTH-1:0] a);
    return a[OFF_BITS+IDX_BITS +: TAG_BITS];
  endfunction

  // Issue-order fifo pointer helpers (MSHR_DEPTH is not required to be a
  // power of two, so wrap explicitly rather than relying on width overflow).
  function automatic logic [MSHR_W-1:0] fifo_inc(input logic [MSHR_W-1:0] p);
    return (p == MSHR_W'(MSHR_DEPTH - 1)) ? '0 : p + 1'b1;
  endfunction

  function automatic logic [MSHR_W-1:0] fifo_wrap(input logic [MSHR_W:0] p);
    return (p >= (MSHR_W + 1)'(MSHR_DEPTH))
           ? MSHR_W'(p - MSHR_DEPTH) : MSHR_W'(p);
  endfunction

  // --------------------
  // Tag / data / MSHR
  // --------------------
  logic tag_lookup, tag_hit, tag_row_valid;
  logic tag_launch;
  logic [IDX_BITS-1:0] tag_launch_index;
  logic [WAY_W-1:0] tag_way;
  logic [SET_ASSOC-1:0] tag_way_valid;
  logic tag_write, tag_inval, tag_match_inval;
  logic [IDX_BITS-1:0] tag_windex, tag_iindex, tag_match_index;
  logic [WAY_W-1:0] tag_wway, tag_iway, tag_probe_way;
  logic [TAG_BITS-1:0] tag_wtag, tag_ltag, tag_probe_tag, tag_match_tag;
  logic tag_wvalid, tag_probe_valid;

  // L3→L2 back-inval: the tag match completes in at most two cycles under
  // TAG_SRAM (one read + one deferred clear, pipelined — a steady stream
  // still retires one match per cycle), so the port stays always-ready. It
  // must never depend combinationally on l2_back_inval_valid_i: the cluster
  // ANDs it into the L3 victim-accept edge.
  // Also used for write-through self-inval: WT bypass must drop a cached
  // line that covers the write address, else a later read hits stale L2 data
  // (store@+0 then store@+16 on same 64 B line → second load returned 0).
  assign l2_back_inval_ready_o = 1'b1;
  logic wr_self_inval;
  logic [AXI_ADDR_WIDTH-1:0] wr_self_inval_addr;
  // The two invalidation sources share one match port, so an external snoop
  // would otherwise discard a same-cycle write self-invalidation and leave the
  // written line cached. The deferred request is held until it is applied, and
  // no new request is accepted meanwhile, so no read can hit the stale line.
  logic wr_inval_pend_q, wr_inval_pend_d;
  logic [AXI_ADDR_WIDTH-1:0] wr_inval_addr_q, wr_inval_addr_d;
  logic [AXI_ADDR_WIDTH-1:0] self_inval_addr;
  logic self_inval_req, kill_match;
  // Declared beside its consumer: the write-update tag-clear mask for
  // wr_self_inval (driven by the decision block near S_BYPASS_* handling).
  logic wu_tag_inval;
  // WRITE_UPDATE: a resident-hit write suppresses the tag clear but never
  // the fill kill — an in-flight fill for the same line must die either
  // way, or it would install pre-write data over the merged line.
  assign self_inval_req  = (wr_self_inval && wu_tag_inval) | wr_inval_pend_q;
  assign kill_match      = l2_back_inval_valid_i | wr_self_inval | wr_inval_pend_q;
  assign self_inval_addr = wr_inval_pend_q ? wr_inval_addr_q : wr_self_inval_addr;
  assign tag_match_inval = l2_back_inval_valid_i | self_inval_req;
  assign tag_match_index = idx_of(l2_back_inval_valid_i ? l2_back_inval_addr_i
                                                       : self_inval_addr);
  assign tag_match_tag   = tag_of(l2_back_inval_valid_i ? l2_back_inval_addr_i
                                                       : self_inval_addr);

  // --------------------
  // T9h/M5 prefetcher plumbing (PF_EN)
  // --------------------
  // g6lc_l2_pf offers ≤1 candidate line. Admission runs from S_IDLE only —
  // demand work in S_TAG always owns the MSHR/tag ports — via a silent tag
  // row launch + lookup on the candidate's set, the MSHR lookup CAM, the
  // R1 write-tracker line probe, the PF_MSHR_RESERVE free-entry floor and a
  // free-way check (a prefetch never displaces a resident line: all-valid
  // sets are dropped, not evicted). A committed candidate becomes a
  // pf-flagged fill entry — issued, collected, installed and kill-matched
  // exactly like a demand fill, with no waiter. At serve time a pf head
  // carrying no waiters retires without the slave R channel; a head that
  // picked up a same-line waiter enters the serve path at S_SERVE_POP (its
  // stored id/len are never used — the waiter's meta drives the burst).
  // Every probe muxes off registered candidate state on idle cycles —
  // nothing here lengthens the S_TAG hit compare or the fill-issue path.
  logic                          pf_cand_vld, pf_cand_take;
  logic [AXI_ADDR_WIDTH-1:0]     pf_cand_line;
  logic                          pf_train;
  logic                          pf_probe_q, pf_probe_d;
  logic                          pf_row_q, pf_row_d;
  logic [AXI_ADDR_WIDTH-1:0]     pf_addr_q, pf_addr_d;
  logic                          pf_launch, pf_launch_ok, pf_capture;
  logic                          pf_probe_fire, pf_alloc;
  logic                          pf_way_ok;
  logic [WAY_W-1:0]              pf_way;
  logic [SET_ASSOC-1:0]          pf_pend_way;
  logic [AXI_ADDR_WIDTH-1:0]     pf_launch_addr;
  logic                          tag_wpf, tag_hit_pf;
  logic [MSHR_DEPTH-1:0]         fill_pf_q, fill_pf_d;
  logic                          head_pf, pf_retire;

  g6lc_l2_tag #(
      .NUM_SETS  (NUM_SETS),
      .SET_ASSOC (SET_ASSOC),
      .TAG_WIDTH (TAG_BITS),
      .IDX_WIDTH (IDX_BITS),
      .TAG_SRAM  (TAG_SRAM),
      .WRITE_UPDATE (WRITE_UPDATE),
      .PF_TAG    (PF_EN)
  ) i_tag (
      .clk_i,
      .rst_ni,
      .launch_i     (tag_launch),
      .launch_index_i(tag_launch_index),
      .lookup_i     (tag_lookup),
      .index_i      (tag_iindex),
      .tag_i        (tag_ltag),
      .hit_o        (tag_hit),
      .way_o        (tag_way),
      .way_valid_o  (tag_way_valid),
      .row_valid_o  (tag_row_valid),
      .probe_way_i  (tag_probe_way),
      .probe_tag_o  (tag_probe_tag),
      .probe_valid_o(tag_probe_valid),
      .write_i      (tag_write),
      .write_index_i(tag_windex),
      .write_way_i  (tag_wway),
      .write_tag_i  (tag_wtag),
      .write_valid_i(tag_wvalid),
      .write_pf_i   (tag_wpf),
      .hit_pf_o     (tag_hit_pf),
      .inval_i      (tag_inval),
      .inval_index_i(tag_iindex),
      .inval_way_i  (tag_iway),
      .inval_match_i      (tag_match_inval),
      .inval_match_index_i(tag_match_index),
      .inval_match_tag_i  (tag_match_tag),
      .inval_match_hit_o  (l2_selfinv_hit_o)
  );

  logic data_a_req, data_a_we, data_b_req, data_b_we, bank_conflict;
  logic [IDX_BITS-1:0] data_a_idx, data_b_idx;
  logic [WAY_W-1:0] data_a_way, data_b_way;
  logic [LINE_WIDTH-1:0] data_a_wdata, data_a_rdata, data_b_wdata, data_b_rdata;
  logic [LINE_WIDTH/8-1:0] data_a_be, data_b_be;

  g6lc_l2_data #(
      .NUM_SETS  (NUM_SETS),
      .SET_ASSOC (SET_ASSOC),
      .LINE_WIDTH(LINE_WIDTH),
      .NUM_BANKS (DATA_BANKS),
      .IDX_WIDTH (IDX_BITS)
  ) i_data (
      .clk_i,
      .rst_ni,
      .a_req_i   (data_a_req),
      .a_we_i    (data_a_we),
      .a_index_i (data_a_idx),
      .a_way_i   (data_a_way),
      .a_wdata_i (data_a_wdata),
      .a_be_i    (data_a_be),
      .a_rdata_o (data_a_rdata),
      .b_req_i   (data_b_req),
      .b_we_i    (data_b_we),
      .b_index_i (data_b_idx),
      .b_way_i   (data_b_way),
      .b_wdata_i (data_b_wdata),
      .b_be_i    (data_b_be),
      .b_rdata_o (data_b_rdata),
      .bank_conflict_o(bank_conflict)
  );
  assign l2_bank_conflict_o = bank_conflict;

  logic mshr_alloc, mshr_ready, mshr_merged, mshr_complete, mshr_full, mshr_empty;
  logic [MSHR_W-1:0] mshr_alloc_idx, mshr_complete_idx;
  logic [MSHR_DEPTH-1:0] fill_kill_q, fill_kill_d;
  logic [AXI_ID_WIDTH-1:0] mshr_complete_id;
  logic [AXI_ADDR_WIDTH-1:0] mshr_alloc_line;
  // Hit-under-miss: waiter payload is the requester's own AXI read shape, so a
  // merged reader is served its own beats rather than the primary's. A waiter
  // is on the same line as the primary by construction, so only the in-line
  // offset is stored — keeping the full address here cost ~4x the waiter flops.
  localparam int unsigned MSHR_META_W = OFF_BITS + 8 + 3;
  logic                    mshr_lookup_hit;
  logic [MSHR_DEPTH-1:0]   mshr_id_match;
  logic [MSHR_W-1:0]       mshr_lookup_idx;
  logic [AXI_ID_WIDTH-1:0] mshr_alloc_id;
  logic [MSHR_META_W-1:0]  mshr_alloc_meta;
  logic                    mshr_waiter_pop, mshr_waiter_valid;
  logic [AXI_ID_WIDTH-1:0] mshr_waiter_id;
  logic [MSHR_META_W-1:0]  mshr_waiter_meta;
  logic [OFF_BITS-1:0]     waiter_off;
  logic [7:0]              waiter_len;
  logic [2:0]              waiter_size;
  logic [MSHR_W:0]         mshr_count;
  assign {waiter_off, waiter_len, waiter_size} = mshr_waiter_meta;
  // Optional round-robin victim pointer (RR_EN). rr_adv strobes on a
  // successful install; rr_victim_way is the pointer read for the current set.
  logic rr_adv;
  logic [WAY_W-1:0] rr_victim_way;

  g6lc_l2_mshr #(
      .DEPTH       (MSHR_DEPTH),
      .ADDR_WIDTH  (AXI_ADDR_WIDTH),
      .ID_WIDTH    (AXI_ID_WIDTH),
      .MAX_WAITERS (4),  // multi-core same-line attach depth
      .META_WIDTH  (MSHR_META_W)
  ) i_mshr (
      .clk_i,
      .rst_ni,
      .flush_i           (1'b0),
      .alloc_i           (mshr_alloc),
      .alloc_line_addr_i (mshr_alloc_line),
      .alloc_id_i        (mshr_alloc_id),
      .alloc_meta_i      (mshr_alloc_meta),
      .alloc_is_write_i  (1'b0),
      // A killed (invalidated) fill stays in the table to drain and serve
      // pre-kill waiters, but new same-line readers must not merge into it —
      // they allocate their own entry and re-fetch the post-inval line.
      .merge_block_i     (fill_kill_q),
      .alloc_ready_o     (mshr_ready),
      .alloc_merged_o    (mshr_merged),
      .alloc_idx_o       (mshr_alloc_idx),
      .lookup_line_addr_i(mshr_alloc_line),
      .lookup_hit_o      (mshr_lookup_hit),
      .lookup_idx_o      (mshr_lookup_idx),
      .id_match_o        (mshr_id_match),
      .complete_i        (mshr_complete),
      .complete_idx_i    (mshr_complete_idx),
      .complete_id_o     (mshr_complete_id),
      .waiter_valid_o    (mshr_waiter_valid),
      .waiter_id_o       (mshr_waiter_id),
      .waiter_meta_o     (mshr_waiter_meta),
      .waiter_pop_i      (mshr_waiter_pop),
      .empty_o           (mshr_empty),
      .full_o            (mshr_full),
      .merge_full_o      (),
      .count_o           (mshr_count)
  );
  assign l2_mshr_full_o = mshr_full;

  // --------------------
  // M1b trackers (POSTED_WRITES): write tracker for uniform B routing and
  // the posted-write path, read tracker + R arbiter for bypass reads. All
  // hazard probes compare registered request fields (AW accept / addr_q);
  // the CAMs are WTRK_DEPTH/RDTRK_DEPTH-entry (≤8) and the R arbiter adds
  // one mux level on the slave R data path — nothing here enters the S_TAG
  // hit compare. Under POSTED_WRITES=0 every probe is tied off and the
  // netlist folds to the blocking-path shape.
  // --------------------
  localparam int unsigned WTRK_W = (WTRK_DEPTH <= 1) ? 1 : $clog2(WTRK_DEPTH);
  // All fill ARs issue under the reserved FILL_ID (see the fill engine).
  localparam logic [AXI_ID_WIDTH-1:0] FILL_ID = '1;
  // T9d/M1d: every *postable* write is forwarded downstream on the reserved
  // write id WR_ID ('1 - 1). AXI same-id ordering then guarantees memory
  // applies posted writes in the L2's acceptance order — the merge order —
  // for every pair of same-line writes, same-core or cross-core, with no
  // integration assumption. ATOP/lock/FILL_ID-alias writes keep their
  // original id on the blocking path. The write tracker records the slave
  // id (for the B return) and the downstream id separately.
  localparam logic [AXI_ID_WIDTH-1:0] WR_ID = AXI_ID_WIDTH'('1) - 1;
  localparam int unsigned BFID_SETTLE = 16;

  logic                        wtrk_push, wtrk_full, wtrk_empty;
  logic [WTRK_W-1:0]           wtrk_alloc_idx, wtrk_pop_idx;
  logic                        wtrk_m_match, wtrk_sb_valid, wtrk_pop;
  logic                        wtrk_sb_blocking;
  logic [AXI_ID_WIDTH-1:0]     wtrk_sb_id;
  logic [1:0]                  wtrk_sb_resp;
  logic [AXI_USER_WIDTH-1:0]   wtrk_sb_user;
  logic                        wtrk_line0_match, wtrk_line1_match;
  logic                        wtrk_line0_wu, wtrk_mark;
  logic [AXI_ID_WIDTH-1:0]     wtrk_line1_id;
  logic                        wtrk_need_r_match;
  logic                        rdtrk_push, rdtrk_pop, rdtrk_full, rdtrk_empty;
  logic                        rdtrk_head_match;
  logic [3:0]                  rdtrk_probe_match;
  logic                        aw_postable;
  logic [AXI_ID_WIDTH-1:0]     aw_dsid;
  logic                        wtrk_aw_ok;
  logic                        wr_posted_q, wr_posted_d;
  logic [WTRK_W-1:0]           wr_trk_idx_q, wr_trk_idx_d;
  logic                        r_rdtrk_active_q, r_rdtrk_active_d;
  logic                        r_turn_q, r_turn_d;
  logic                        rdtrk_wants, rdtrk_grant;
  logic                        fsm_in_r, fsm_wants_r, r_fsm_start_ok;


  // --------------------
  // Controller FSM (request pipeline) + decoupled fill engine
  //
  // The request pipeline accepts ARs, runs tag lookup, serves hits and parks
  // misses in the MSHR without blocking: a fresh miss pushes a fill request
  // into the fill engine and returns to S_IDLE. The fill engine issues line
  // fills on the memory port, collects the R beats into per-entry line
  // buffers, installs completed lines, and exposes serve-ready entries back
  // to the pipeline, which drains them (primary + merged waiters) on the
  // slave R channel. Multiple fills are therefore outstanding concurrently
  // (true MLP) while the slave side keeps a single ordered response stream.
  // --------------------
  typedef enum logic [3:0] {
    S_IDLE,
    S_TAG,
    S_HIT_WAIT,
    S_HIT_RESP,
    S_SERVE,
    S_SERVE_POP,
    S_BYPASS_AR,
    S_BYPASS_R,
    S_BYPASS_AW,
    S_BYPASS_W,
    S_BYPASS_B
  } state_e;

  state_e state_q, state_d;
  logic write_turn_q, prefer_write;
  assign prefer_write = FAIR_WRITES && write_turn_q && slv_req_i.aw_valid;
  if (FAIR_WRITES) begin : gen_write_fairness
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) write_turn_q <= 1'b0;
      else if (slv_req_i.aw_valid && slv_resp_o.aw_ready) write_turn_q <= 1'b0;
      else if ((slv_req_i.ar_valid && slv_resp_o.ar_ready) ||
               (state_q == S_IDLE && state_d == S_SERVE)) write_turn_q <= 1'b1;
    end
  end else begin : gen_legacy_write_priority
    assign write_turn_q = 1'b0;
  end

  // Captured request
  logic [AXI_ADDR_WIDTH-1:0] addr_q, addr_d;
  logic [AXI_ID_WIDTH-1:0]   id_q, id_d;
  logic [7:0]                len_q, len_d;
  logic [2:0]                size_q, size_d;
  logic [3:0]                cache_q, cache_d;
  logic [5:0]                atop_q, atop_d;  // AXI ATOP (AMOs / AMOCAS)
  logic                      lock_q, lock_d;
  logic                      burst_incr_q, burst_incr_d;
  logic                      is_write_q, is_write_d;
  logic                      cacheable_q, cacheable_d;
  logic [WAY_W-1:0]          way_q, way_d;
  logic [LINE_WIDTH-1:0]     line_q, line_d;
  // S_HIT_WAIT may park for many cycles under the R5 hold — the port-A read
  // result is only fresh on the entry cycle, so line_q may latch it once.
  logic                      hit_fresh_q, hit_fresh_d;
  // First AXI beat index within the L2 line for the captured AR address.
  // Without this, a hit on a 64 B line always returned beats from offset 0,
  // so I$ fills at +16/+32/... re-read the first 16 B of the line.
  localparam int unsigned BEAT_ADDR_LSB = $clog2(AXI_DATA_WIDTH / 8);
  localparam int unsigned BEAT_IDX_W    = (BEATS <= 1) ? 1 : $clog2(BEATS);
  // beat_q: response *count* (0..len) in S_HIT_RESP/S_SERVE.
  logic [$clog2(BEATS+1)-1:0] beat_q, beat_d;
  // MSHR index of the entry currently being served.
  logic [MSHR_W-1:0]         serve_idx_q, serve_idx_d;
  // Master R outstanding (bypass reads only): after a bypass AR handshake we
  // MUST drain R until r_last, even if the FSM leaves S_BYPASS_R early.
  // Otherwise axi2mem stays in READ with r_valid && !r_ready and all
  // subsequent DRAM traffic deadlocks (OpenSBI hang after MaxMstTrans fix:
  // a2m=READ @0x80000080, L2 IDLE). Fill ARs are tracked separately — the
  // fill collector drains their beats unconditionally.
  logic mst_r_ot_q, mst_r_ot_d;
  logic wr_r_pending_q,wr_r_pending_d,wr_b_done_q,wr_b_done_d;
  // T9a eWT write-idle (CMO clean/flush ordering): no write accepted and not
  // yet B-acknowledged. A blocking write traverses S_BYPASS_AW→W→B with
  // is_write_q latched at AW accept; under POSTED_WRITES a posted write's
  // liveness is its tracker entry, so idle additionally requires the tracker
  // to have drained — idle here also implies memory has observed the write.
  // wtrk_empty is tied high when POSTED_WRITES=0 (folds to the T9a shape).
  assign l2_write_idle_o = !(is_write_q &&
      (state_q == S_BYPASS_AW || state_q == S_BYPASS_W || state_q == S_BYPASS_B)) &&
      wtrk_empty;

  // M1b observability: hold-cycle levels for the PMU group-2 posted-write
  // event and completion pulses for the [mc_cache] counters.
  // M1c split: R1 (read miss behind a tracked write), its write-update-hit
  // subset, and R2 (different-id same-line AW). The ATOP-load guard has no
  // split field and stays in the aggregate only.
  assign l2_wtrk_full_o = POSTED_WRITES && (state_q == S_IDLE) &&
                          slv_req_i.aw_valid && wtrk_full;
  // R1: a cacheable read miss holds while its line has a tracker entry.
  assign l2_hold_r1_o = POSTED_WRITES &&
      (state_q == S_TAG && tag_row_valid && !tag_hit && wtrk_line0_match);
  assign l2_hold_r1_wu_o = l2_hold_r1_o && wtrk_line0_wu;
  // R2 (T9d): AW held because a same-line tracker entry carries a different
  // *downstream* id — posted-vs-posted shares WR_ID and never holds; only
  // posted-vs-blocking or blocking-vs-blocking mismatches still serialize.
  assign l2_hold_r2_o = POSTED_WRITES &&
      (state_q == S_IDLE && slv_req_i.aw_valid && !wtrk_full &&
       wtrk_line1_match && (aw_dsid != wtrk_line1_id));
  assign l2_wtrk_line_hold_o = l2_hold_r1_o | l2_hold_r2_o |
      // ATOP-load guard: AW accepted only when admitted.
      (POSTED_WRITES && state_q == S_IDLE && slv_req_i.aw_valid &&
       !wtrk_full && slv_req_i.aw.atop[5] && rdtrk_probe_match[3]);
  assign l2_posted_hold_o = l2_wtrk_full_o | l2_wtrk_line_hold_o;
  assign l2_posted_o = POSTED_WRITES && wtrk_pop && !wtrk_sb_blocking;
  assign l2_rdtrk_o  = POSTED_WRITES && rdtrk_pop;
  // Serve alternation: set when a fill-serve burst just completed so a
  // pending AR gets the next S_IDLE slot before another serve starts.
  logic serve_turn_q, serve_turn_d;
  // Dedicated serve registers: the request regs (addr_q/id_q/len_q/beat_q)
  // stay captive to a request stalled in S_TAG while a deadlock-breaking
  // serve interrupts it, so the serve datapath carries its own context.
  // serve_intr_q marks a serve started from an S_TAG stall: on completion the
  // FSM returns to S_TAG (not S_IDLE) to retry the captive request's lookup.
  logic [AXI_ADDR_WIDTH-1:0]     serve_addr_q, serve_addr_d;
  logic [AXI_ID_WIDTH-1:0]       serve_id_q,   serve_id_d;
  logic [7:0]                    serve_len_q,  serve_len_d;
  logic [$clog2(BEATS+1)-1:0]    serve_beat_q, serve_beat_d;
  logic                          serve_intr_q, serve_intr_d;
  logic [BEAT_IDX_W-1:0]         serve_base, serve_bidx;
  assign serve_base = serve_addr_q[OFF_BITS-1:BEAT_ADDR_LSB];
  assign serve_bidx = serve_base + BEAT_IDX_W'(serve_beat_q);

  // The primary's id is the captured one: the AR bus has already moved on by
  // the time S_TAG allocates. A merging waiter overrides both below. A PF
  // probe muxes the lookup/alloc line onto the candidate; its entries carry
  // FILL_ID — they never serve a primary burst, so the id is inert.
  assign mshr_alloc_id   = pf_alloc ? FILL_ID : id_q;
  assign mshr_alloc_line = pf_probe_fire ? line_align(pf_addr_q)
                                         : line_align(addr_q);
  // Demand misses commit in S_TAG; a commit is the prefetcher's only
  // training edge (mshr_alloc in S_IDLE is a pf commit — excluded).
  assign pf_train        = PF_EN && mshr_alloc && (state_q == S_TAG);

  // --------------------
  // Fill engine: per-MSHR-entry fill state, line buffers and issue order.
  //
  // All fill ARs issue under the reserved FILL_ID. AXI guarantees same-ID
  // read bursts return in issue order with contiguous beats (no interleave),
  // so a single collect pointer walking the issue-order FIFO routes every
  // fill beat to the right entry without per-entry AXI IDs. FILL_ID is kept
  // exclusive: a bypass/AMO whose id equals FILL_ID never issues while a fill
  // is outstanding, and a fill never issues while a FILL_ID bypass trail is
  // live (bfid_*), so r.id==FILL_ID beats are unambiguously fill beats.
  // (FILL_ID / BFID_SETTLE are declared beside the tracker block above.)
  // --------------------

  typedef enum logic [1:0] {
    F_QUEUED,   // allocated, waiting for AR issue
    F_FILLING,  // AR issued, collecting R beats
    F_DONE,     // all beats collected, waiting to install
    F_READY     // installed (or kill-skipped), waiting to serve
  } fstate_e;

  logic [MSHR_DEPTH-1:0]                   fill_act_q,   fill_act_d;
  fstate_e                                 fill_state_q  [MSHR_DEPTH];
  fstate_e                                 fill_state_d  [MSHR_DEPTH];
  logic [MSHR_DEPTH-1:0][AXI_ADDR_WIDTH-1:0] fill_addr_q,  fill_addr_d;
  logic [MSHR_DEPTH-1:0][WAY_W-1:0]        fill_way_q,   fill_way_d;
  logic [MSHR_DEPTH-1:0][7:0]              fill_len_q,   fill_len_d;
  logic [MSHR_DEPTH-1:0][LINE_WIDTH-1:0]   fill_buf_q,   fill_buf_d;
  logic [MSHR_DEPTH-1:0][BEAT_IDX_W:0]     fill_bcnt_q,  fill_bcnt_d;
  logic [MSHR_DEPTH-1:0][1:0]              fill_ferr_q,  fill_ferr_d;
  // Issue-order FIFO of entry indices: pushed at MSHR alloc, ARs issue from
  // rd+issued_cnt, R beats collect into rd+collect_cnt, the rd head frees
  // when its serve completes.
  logic [MSHR_DEPTH-1:0][MSHR_W-1:0]       fifo_q, fifo_d;
  logic [MSHR_W-1:0]                       fifo_rd_q, fifo_rd_d;
  logic [MSHR_W-1:0]                       fifo_wr_q, fifo_wr_d;
  logic [MSHR_W:0]                         fifo_cnt_q, fifo_cnt_d;
  logic [MSHR_W:0]                         issued_cnt_q, issued_cnt_d;
  logic [MSHR_W:0]                         collect_cnt_q, collect_cnt_d;
  // FILL_ID bypass trail: a FILL_ID bypass AR/AW holds fills off until its
  // response (incl. any injected AMO/ATOP R straggler) has drained.
  logic                                    bfid_rpend_q, bfid_rpend_d;
  logic [5:0]                              bfid_timer_q, bfid_timer_d;
  logic                                    bfid_busy;
  assign bfid_busy = bfid_rpend_q || (bfid_timer_q != '0);

  // Derived fill-engine wires. fifo position = rd + offset wrapped; the
  // counters are distances from rd so the oldest outstanding entry is always
  // at rd+collect_cnt and the next-to-issue at rd+issued_cnt.
  logic [MSHR_W-1:0] collect_pos, issue_pos, collect_idx, issue_idx;
  logic              collect_active, is_fill_beat, fill_out, issue_vld;
  logic              serve_pend;
  logic [MSHR_W-1:0] inst_idx;
  logic              inst_vld;
  // The installed line's pf provenance — tag_wpf is only consumed alongside
  // tag_write at install time.
  assign tag_wpf        = PF_EN && fill_pf_q[inst_idx];
  assign collect_pos    = fifo_wrap((MSHR_W + 1)'(fifo_rd_q) + collect_cnt_q);
  assign issue_pos      = fifo_wrap((MSHR_W + 1)'(fifo_rd_q) + issued_cnt_q);
  assign collect_idx    = fifo_q[collect_pos];
  assign issue_idx      = fifo_q[issue_pos];
  // An issued-but-not-yet-collected fill burst is outstanding on the R
  // channel; the entry at that position is F_FILLING by construction.
  assign collect_active = (collect_cnt_q < issued_cnt_q) &&
                          (fill_state_q[collect_idx] == F_FILLING);
  assign is_fill_beat   = mst_resp_i.r_valid &&
                          (mst_resp_i.r.id == FILL_ID) && collect_active;
  assign fill_out       = (issued_cnt_q != collect_cnt_q);
  assign issue_vld      = (issued_cnt_q < fifo_cnt_q) && !bfid_busy &&
                          (fill_state_q[issue_idx] == F_QUEUED)
                          && !((state_q==S_BYPASS_AW || state_q==S_BYPASS_W || state_q==S_BYPASS_B) && id_q==FILL_ID);
  // A pf fill head with waiters still claims the serve channel (the waiters
  // are demand readers); a waitless pf head retires without a slave burst.
  assign head_pf        = PF_EN && (fifo_cnt_q != '0) &&
                          fill_pf_q[fifo_q[fifo_rd_q]];
  assign serve_pend     = (fifo_cnt_q != '0) &&
                          (fill_state_q[fifo_q[fifo_rd_q]] == F_READY) &&
                          !(head_pf && !mshr_waiter_valid);
  assign pf_retire      = (fifo_cnt_q != '0) &&
                          (fill_state_q[fifo_q[fifo_rd_q]] == F_READY) &&
                          head_pf && !mshr_waiter_valid &&
                          (state_q != S_SERVE) && (state_q != S_SERVE_POP);
  // Postable iff non-atomic, unlocked and outside the reserved fill id —
  // ATOP/lock/FILL_ID-alias writes keep the blocking S_BYPASS_AW→W→B path
  // but still hold a (blocking) tracker entry for uniform B routing.
  assign aw_postable = (slv_req_i.aw.atop == '0) && !slv_req_i.aw.lock &&
                       (slv_req_i.aw.id != FILL_ID);
  // The downstream id the offered AW will be forwarded on: WR_ID for a
  // posted write, the original id for a blocking one.
  assign aw_dsid = aw_postable ? WR_ID : slv_req_i.aw.id;
  // R2 AW admission: free slot, and a same-line entry implies the same
  // *downstream* id — per-id B order then alone routes same-line write
  // completions, so two posted writes (both WR_ID) never serialize here;
  // only a posted write meeting a blocking entry (or two blocking entries
  // on different ids) still waits. An ATOP-load (atop[5]) may not enter
  // while a tracked bypass read carries its id: the ATOP R forward and the
  // read-tracked beats share the slave R channel and could not be told
  // apart.
  assign wtrk_aw_ok = !POSTED_WRITES ||
                      (!wtrk_full &&
                       (!wtrk_line1_match ||
                        (aw_dsid == wtrk_line1_id)) &&
                       !(slv_req_i.aw.atop[5] && rdtrk_probe_match[3]));
  // Slave-R arbiter. An in-progress tracked burst owns the channel until
  // last; a new burst picks round-robin (r_turn_q: 1 favors memory-side
  // beats, 0 favors FSM-internal bursts). FSM bursts only claim the channel
  // through r_fsm_start_ok-gated transitions, so a tracked burst can never
  // be interleaved.
  assign rdtrk_wants = POSTED_WRITES && mst_resp_i.r_valid &&
                       rdtrk_head_match && !is_fill_beat;
  assign fsm_in_r    = (state_q == S_HIT_RESP) || (state_q == S_SERVE) ||
                       (state_q == S_BYPASS_R &&
                        mst_resp_i.r_valid && (mst_resp_i.r.id == id_q) &&
                        !rdtrk_head_match) ||
                       (((state_q == S_BYPASS_AW) || (state_q == S_BYPASS_W) ||
                         (state_q == S_BYPASS_B)) &&
                        wr_r_pending_q && mst_resp_i.r_valid &&
                        (mst_resp_i.r.id == id_q) && !is_fill_beat) ||
                       (state_q == S_IDLE && mst_resp_i.r_valid &&
                        !mst_r_ot_q && !is_fill_beat && !rdtrk_head_match);
  assign fsm_wants_r = (state_q == S_HIT_WAIT) || (state_q == S_SERVE_POP) ||
                       (serve_pend && ((state_q == S_IDLE) ||
                                       (state_q == S_TAG) ||
                                       (state_q == S_BYPASS_AR)));
  assign rdtrk_grant = r_rdtrk_active_q ? rdtrk_wants
                       : (rdtrk_wants && !fsm_in_r &&
                          (r_turn_q || !fsm_wants_r));
  assign r_fsm_start_ok = !r_rdtrk_active_q && !(rdtrk_wants && r_turn_q);

  if (POSTED_WRITES) begin : gen_trk
    g6lc_l2_wtrk #(
        .DEPTH          (WTRK_DEPTH),
        .ID_WIDTH       (AXI_ID_WIDTH),
        .ADDR_WIDTH     (AXI_ADDR_WIDTH),
        .AXI_USER_WIDTH (AXI_USER_WIDTH)
    ) i_wtrk (
        .clk_i,
        .rst_ni,
        .push_i            (wtrk_push),
        .push_id_i         (slv_req_i.aw.id),
        .push_dsid_i       (aw_dsid),
        .push_line_i       (line_align(slv_req_i.aw.addr)),
        .push_blocking_i   (!aw_postable),
        .push_need_r_i     (slv_req_i.aw.atop[5]),
        .mark_i            (wtrk_mark),
        .mark_idx_i        (wr_trk_idx_q),
        .full_o            (wtrk_full),
        .alloc_idx_o       (wtrk_alloc_idx),
        .m_b_valid_i       (mst_resp_i.b_valid),
        .m_b_id_i          (mst_resp_i.b.id),
        .m_b_resp_i        (mst_resp_i.b.resp),
        .m_b_user_i        (mst_resp_i.b.user),
        .m_b_match_o       (wtrk_m_match),
        .s_b_valid_o       (wtrk_sb_valid),
        .s_b_id_o          (wtrk_sb_id),
        .s_b_resp_o        (wtrk_sb_resp),
        .s_b_user_o        (wtrk_sb_user),
        .s_b_blocking_o    (wtrk_sb_blocking),
        .s_b_ready_i       (slv_req_i.b_ready),
        .pop_o             (wtrk_pop),
        .pop_idx_o         (wtrk_pop_idx),
        .line0_i           (pf_probe_fire ? line_align(pf_addr_q)
                                          : line_align(addr_q)),
        .line0_match_o     (wtrk_line0_match),
        .line0_wu_o        (wtrk_line0_wu),
        .line1_i           (line_align(slv_req_i.aw.addr)),
        .line1_match_o     (wtrk_line1_match),
        .line1_match_id_o  (wtrk_line1_id),
        .need_r_id_i       (id_q),
        .need_r_id_match_o (wtrk_need_r_match),
        .empty_o           (wtrk_empty)
    );

    // Probe map: [0] captured request id (hit responses), [1] fill-serve id
    // (mshr_complete_id), [2] waiter id (serve pop), [3] slave AW id (the
    // ATOP-load admission guard). R5: a same-id response holds until the
    // tracked read's entry pops.
    g6lc_l2_rdtrk #(
        .DEPTH    (RDTRK_DEPTH),
        .ID_WIDTH (AXI_ID_WIDTH),
        .NPROBE   (4)
    ) i_rdtrk (
        .clk_i,
        .rst_ni,
        .push_i        (rdtrk_push),
        .push_id_i     (id_q),
        .full_o        (rdtrk_full),
        .r_id_i        (mst_resp_i.r.id),
        .head_match_o  (rdtrk_head_match),
        .pop_i         (rdtrk_pop),
        .probe_id_i    ({slv_req_i.aw.id, mshr_waiter_id,
                         mshr_complete_id, id_q}),
        .probe_match_o (rdtrk_probe_match),
        .empty_o       (rdtrk_empty)
    );

    if (!SLV_WRID_OK) begin : gen_wrid_chk
      // T9d/M1d: WR_ID is reserved for this engine's own re-tagging. A
      // postable slave write arriving already on WR_ID means upstream
      // violated the reservation (hub slot ids stay in 0..13; ATOP/lock
      // writes on WR_ID keep their original id on the blocking path and
      // are legal). In an L3 stack the inner engine sets SLV_WRID_OK — its
      // L2's posted writes arrive on WR_ID by design.
      //pragma translate_off
      always_ff @(posedge clk_i) begin
        if (rst_ni && slv_req_i.aw_valid && aw_postable &&
            (slv_req_i.aw.id == WR_ID))
          $error("%m: postable slave write arrived on reserved WR_ID");
      end
      //pragma translate_on
    end
  end else begin : gen_no_trk
    assign wtrk_full         = 1'b0;
    assign wtrk_empty        = 1'b1;
    assign wtrk_alloc_idx    = '0;
    assign wtrk_pop_idx      = '0;
    assign wtrk_m_match      = 1'b0;
    assign wtrk_sb_valid     = 1'b0;
    assign wtrk_sb_blocking  = 1'b0;
    assign wtrk_sb_id        = '0;
    assign wtrk_sb_resp      = '0;
    assign wtrk_sb_user      = '0;
    assign wtrk_pop          = 1'b0;
    assign wtrk_line0_match  = 1'b0;
    assign wtrk_line0_wu     = 1'b0;
    assign wtrk_line1_match  = 1'b0;
    assign wtrk_line1_id     = '0;
    assign wtrk_need_r_match = 1'b0;
    assign rdtrk_full        = 1'b0;
    assign rdtrk_empty       = 1'b1;
    assign rdtrk_head_match  = 1'b0;
    assign rdtrk_probe_match = '0;
  end

  logic merge_order_block, after_match;
  logic fill_ar_hold_q, fill_ar_hold_d;
  logic fill_ar_offer, bypass_ar_offer;
  always_comb begin
    merge_order_block=1'b0;
    after_match=1'b0;
    for(int unsigned n=0;n<MSHR_DEPTH;n++)begin
      if(n<int'(fifo_cnt_q))begin
        if(mshr_lookup_hit && fifo_q[fifo_wrap((MSHR_W+1)'(fifo_rd_q)+(MSHR_W+1)'(n))]==mshr_lookup_idx)
          after_match=1'b1;
        else if(after_match && mshr_id_match[fifo_q[fifo_wrap((MSHR_W+1)'(fifo_rd_q)+(MSHR_W+1)'(n))]])
          merge_order_block=1'b1;
      end
    end
  end
  assign bypass_ar_offer=(state_q==S_BYPASS_AR) && !(|mshr_id_match) &&
                         !(id_q==FILL_ID && fill_out) && !fill_ar_hold_q;
  assign fill_ar_offer=fill_ar_hold_q || (issue_vld &&
                       (state_q!=S_BYPASS_AR || (|mshr_id_match)));
  // Oldest fill-done entry awaiting install (lowest MSHR index wins).
  always_comb begin
    inst_vld = 1'b0;
    inst_idx = '0;
    for (int unsigned e = 0; e < MSHR_DEPTH; e++) begin
      if (!inst_vld && fill_act_q[e] && (fill_state_q[e] == F_DONE)) begin
        inst_vld = 1'b1;
        inst_idx = MSHR_W'(e);
      end
    end
  end

  logic [BEAT_IDX_W-1:0] beat_base;
  logic [BEAT_IDX_W-1:0] beat_idx;
  assign beat_base = addr_q[OFF_BITS-1:BEAT_ADDR_LSB];
  assign beat_idx  = beat_base + BEAT_IDX_W'(beat_q);

  // Write-update decision state: valid for the duration of one bypassed
  // write, cleared on return to S_IDLE. wu_hit_q/wu_way_q name the resident
  // line the W beats merge into; wu_beat_q counts forwarded beats so each
  // lands at its burst offset inside the line.
  logic wu_decided_q, wu_decided_d;
  logic wu_hit_q, wu_hit_d;
  logic [WAY_W-1:0] wu_way_q, wu_way_d;
  logic [BEAT_IDX_W-1:0] wu_beat_q, wu_beat_d;
  logic wu_fill_same_line, wu_eligible, wu_candidate, wu_hit_now;
  logic wu_merge_wr, wu_install_stall, data_a_req_hit;
  logic [23:0] wu_span;
  logic [LINE_WIDTH/8-1:0] wu_be;

  logic [SET_ASSOC-1:0] pend_way;
  logic found_inv, way_ok;
  logic [WAY_W-1:0] victim_way;
  always_comb begin
    pend_way = '0;
    for (int unsigned e = 0; e < MSHR_DEPTH; e++) begin
      if (fill_act_q[e] && (fill_state_q[e] != F_READY) &&
          (idx_of(fill_addr_q[e]) == idx_of(addr_q)))
        pend_way[fill_way_q[e]] = 1'b1;
    end
    found_inv = 1'b0;
    victim_way = (RR_EN && (&tag_way_valid)) ? rr_victim_way : '0;
    for (int w = 0; w < int'(SET_ASSOC); w++) begin
      if (!found_inv && !tag_way_valid[w]) begin
        victim_way = WAY_W'(w);
        found_inv = 1'b1;
      end
    end
    way_ok = !pend_way[victim_way];
    for (int w = 0; w < int'(SET_ASSOC); w++) begin
      if (!way_ok && !pend_way[w]) begin
        victim_way = WAY_W'(w);
        way_ok = 1'b1;
      end
    end
  end
  assign tag_probe_way = victim_way;

  // PF way pick: an invalid way in the candidate's set not already claimed
  // by an in-flight fill — a prefetch never evicts, so an all-valid or all-
  // pending set drops the candidate instead. tag_way_valid reflects
  // index_i, which the probe fire muxes to the candidate's set.
  always_comb begin
    pf_pend_way = '0;
    for (int unsigned e = 0; e < MSHR_DEPTH; e++) begin
      if (fill_act_q[e] && (fill_state_q[e] != F_READY) &&
          (idx_of(fill_addr_q[e]) == idx_of(pf_addr_q)))
        pf_pend_way[fill_way_q[e]] = 1'b1;
    end
    pf_way    = '0;
    pf_way_ok = 1'b0;
    for (int w = 0; w < int'(SET_ASSOC); w++) begin
      if (!tag_way_valid[w] && !pf_pend_way[w] && !pf_way_ok) begin
        pf_way    = WAY_W'(w);
        pf_way_ok = 1'b1;
      end
    end
  end

  if (PF_EN) begin : gen_pf
    g6lc_l2_pf #(
      .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
      .LINE_BYTES     (LINE_WIDTH / 8),
      .NR_STREAMS     (PF_STREAMS),
      .PF_DISTANCE    (PF_DISTANCE),
      .STRIDE_EN      (PF_STRIDE)
    ) i_pf (
      .clk_i,
      .rst_ni,
      .train_i      (pf_train),
      .train_line_i (line_align(addr_q)),
      .cand_valid_o (pf_cand_vld),
      .cand_line_o  (pf_cand_line),
      .cand_take_i  (pf_cand_take)
    );
    assign pf_cand_take = pf_capture;
  end else begin : gen_no_pf
    assign pf_cand_vld  = 1'b0;
    assign pf_cand_line = '0;
    assign pf_cand_take = 1'b0;
  end

  // Admission sequencing: a captured candidate gets its tag row launched
  // while the launch port is free (demand S_TAG relaunch and the WU write
  // probe own it otherwise); pf_row_q remembers whose row is in flight so
  // an inval-match steal re-launches. The probe evaluates — silently, one
  // cycle minimum after capture — on the first S_IDLE cycle that owns the
  // registered row.
  assign pf_launch_ok  = PF_EN &&
                         !(state_d == S_TAG) &&
                         !(WRITE_UPDATE && (state_q == S_IDLE) &&
                           (state_d == S_BYPASS_AW));
  assign pf_launch_addr = pf_probe_q ? pf_addr_q : pf_cand_line;
  assign pf_capture    = pf_cand_vld && !pf_probe_q && pf_launch_ok;
  // Relaunch each cycle while armed: same-index re-reads are idempotent, and
  // keeping pf_probe_fire out of the launch term severs the combinational
  // pf_launch -> tag row_valid -> probe -> launch loop under TAG_SRAM.
  assign pf_launch     = pf_launch_ok && (pf_capture || pf_probe_q);
  assign pf_probe_fire = PF_EN && pf_probe_q && (state_q == S_IDLE) &&
                         pf_row_q && tag_row_valid;

  logic install_discard;
  assign install_discard = fill_kill_q[inst_idx] ||
      (fill_ferr_q[inst_idx] != axi_pkg::RESP_OKAY) ||
      (l2_back_inval_valid_i &&
       line_align(fill_addr_q[inst_idx]) == line_align(l2_back_inval_addr_i)) ||
      (wr_inval_pend_q &&
       line_align(fill_addr_q[inst_idx]) == line_align(wr_inval_addr_q)) ||
      ((state_q == S_BYPASS_AW || state_q == S_BYPASS_W) &&
       line_align(fill_addr_q[inst_idx]) == line_align(addr_q));
  // ---------------- WRITE_UPDATE: resident-line write merge ----------------
  // Ordering: a write is globally ordered by its B response — the hub drops
  // the writer's L1 copy at B, so anything a reader can be served before B
  // may be pre-write, and everything after must carry the write's bytes.
  // Merging the forwarded beats into the resident line satisfies the same
  // bound as purging it: the FSM only leaves through S_BYPASS_B after B
  // lands, so no reader can be served the merged line before memory has
  // acknowledged the write (the composed bench's late_ar >= mem_b contract
  // still holds with WRITE_UPDATE on).
  // Eligibility (all on registered AW fields): cacheable, non-atomic,
  // unlocked, and the whole burst confined to the addressed line — a
  // single beat of any size (WSTRB already names its lanes) or a
  // full-width multi-beat INCR run that ends inside the line. Atomics and
  // locked writes carry a memory-side result and must drop the cached
  // copy; non-cacheable writes and bursts that would wrap inside the line
  // keep the invalidate-and-kill path. An in-flight fill for the same line
  // makes the write ineligible (defensive — a fill implies an earlier
  // miss, so a hit cannot co-exist with one; kill_match drops it anyway).
  assign wu_span = 24'(addr_q[OFF_BITS-1:0]) +
                   ((24'(len_q) + 24'd1) << size_q);
  assign wu_eligible = WRITE_UPDATE && is_write_q && cacheable_q &&
                       (atop_q == '0) && !lock_q && !wu_fill_same_line &&
                       (len_q == 8'd0 ||
                        (burst_incr_q &&
                         size_q == 3'($clog2(AXI_DATA_WIDTH / 8)))) &&
                       (wu_span <= 24'(LINE_BYTES));
  // Still-deciding candidate: an eligible write whose launched row survived
  // the S_IDLE accept edge (an inval-match steal yields !tag_row_valid and
  // the write conservatively invalidates). Its tag clear defers one cycle
  // while the compare resolves; a miss then invalidates exactly as before,
  // a hit suppresses it entirely.
  assign wu_candidate = wu_eligible && !wu_decided_q && tag_row_valid;
  assign wu_hit_now   = wu_decided_q ? wu_hit_q : (wu_candidate && tag_hit);
  assign wu_tag_inval = !wu_hit_now && !wu_candidate;
  // M1c: mark the tracked entry write-update-hit on its decide cycle so an
  // R1 hold against it is attributed write-update vs write-around. One
  // pulse — wu_candidate is live only until wu_decided_q latches.
  assign wtrk_mark = POSTED_WRITES && (state_q == S_BYPASS_AW) &&
                     wu_candidate && tag_hit;
  // A same-line fill cannot co-exist with a resident tag (see above) — the
  // predicate is defensive, kill_match removes the fill regardless.
  always_comb begin
    wu_fill_same_line = 1'b0;
    for (int unsigned e = 0; e < MSHR_DEPTH; e++) begin
      if (fill_act_q[e] && (fill_state_q[e] != F_READY) &&
          (line_align(fill_addr_q[e]) == line_align(addr_q)))
        wu_fill_same_line = 1'b1;
    end
  end
  // Forwarded-beat merge into the resident line via data port A — the
  // demand port, which wins same-bank conflicts in g6lc_l2_data while the
  // fill installer retries on bank_conflict, so a merge always lands. The
  // W stream itself never stalls: slv w_ready stays the transparent
  // mst w_ready. Each beat's byte lanes are shifted to
  // (burst-start word + beat count) inside the line.
  assign wu_merge_wr = wu_hit_q && (state_q == S_BYPASS_W) &&
                       slv_req_i.w_valid && mst_resp_i.w_ready;
  assign wu_be = (LINE_WIDTH/8)'(slv_req_i.w.strb)
                 << (((BEAT_IDX_W+1)'(beat_base) + (BEAT_IDX_W+1)'(wu_beat_q))
                     * STRB_W);
  // A fill for a DIFFERENT line must not claim the merge's way while beats
  // are in flight: its install writes tag+line wholesale, so the bytes
  // merged so far die while later merge beats would still write the old
  // tag's line. Stall such an install until the write drains into
  // S_BYPASS_B — a post-merge install is a full-line write and wins
  // cleanly. Same-line fills never reach here (kill_match discards them).
  assign wu_install_stall = wu_hit_now && inst_vld &&
                            (state_q == S_BYPASS_AW || state_q == S_BYPASS_W) &&
                            (idx_of(fill_addr_q[inst_idx]) == idx_of(addr_q)) &&
                            (fill_way_q[inst_idx] ==
                             (wu_decided_q ? wu_way_q : tag_way));
  // One pulse per write handled as a merge (its last forwarded beat).
  assign l2_wupdate_o = wu_merge_wr && slv_req_i.w.last;

  assign data_a_req_hit = (state_q == S_TAG) && tag_hit && !(|mshr_id_match);
  assign data_a_req = data_a_req_hit | wu_merge_wr;
  assign data_a_we  = wu_merge_wr;
  assign data_a_idx = idx_of(addr_q);
  assign data_a_way = wu_merge_wr ? wu_way_q
                                  : (data_a_req_hit ? tag_way : way_q);
  // wdata stays '0 under WRITE_UPDATE=0 so the port-A write input folds
  // away and the netlist is unchanged.
  assign data_a_wdata = WRITE_UPDATE ? {BEATS{slv_req_i.w.data}} : '0;
  assign data_a_be = wu_merge_wr ? wu_be : '1;
  assign data_b_req = inst_vld && !install_discard && !wu_install_stall;
  assign data_b_we = data_b_req;
  assign data_b_idx = data_b_req ? idx_of(fill_addr_q[inst_idx]) : idx_of(addr_q);
  assign data_b_way = data_b_req ? fill_way_q[inst_idx] : way_q;
  assign data_b_wdata = data_b_req ? fill_buf_q[inst_idx] : line_q;
  assign data_b_be = '1;

  // AXI slave defaults
  always_comb begin
    // Slave response
    slv_resp_o = '0;
    slv_resp_o.aw_ready = 1'b0;
    slv_resp_o.w_ready  = 1'b0;
    slv_resp_o.b_valid  = 1'b0;
    slv_resp_o.ar_ready = 1'b0;
    slv_resp_o.r_valid  = 1'b0;

    // Master request
    mst_req_o = '0;
    mst_req_o.aw_valid = 1'b0;
    mst_req_o.w_valid  = 1'b0;
    mst_req_o.b_ready  = 1'b0;
    mst_req_o.ar_valid = 1'b0;
    mst_req_o.r_ready  = 1'b0;

    // Tag/data/mshr defaults
    tag_lookup = 1'b0;
    tag_write  = 1'b0;
    tag_inval  = 1'b0;
    tag_iindex = idx_of(addr_q);
    tag_ltag   = tag_of(addr_q);
    tag_windex = idx_of(addr_q);
    tag_wway   = way_q;
    tag_wtag   = tag_of(addr_q);
    tag_wvalid = 1'b1;
    tag_iway   = way_q;


    mshr_alloc       = 1'b0;
    mshr_alloc_meta  = {addr_q[OFF_BITS-1:0], len_q, size_q};
    mshr_waiter_pop  = 1'b0;
    mshr_complete    = 1'b0;
    // The serve engine's entry: the registered pick while draining, else the
    // issue-order fifo head (the S_IDLE serve candidate). All waiter/complete
    // probes of the MSHR index off this.
    mshr_complete_idx = ((state_q == S_SERVE) || (state_q == S_SERVE_POP))
                        ? serve_idx_q : fifo_q[fifo_rd_q];
    rr_adv           = 1'b0;

    // Fill engine defaults
    fill_act_d    = fill_act_q;
    fill_state_d  = fill_state_q;
    fill_kill_d   = fill_kill_q;
    fill_addr_d   = fill_addr_q;
    fill_way_d    = fill_way_q;
    fill_len_d    = fill_len_q;
    fill_buf_d    = fill_buf_q;
    fill_bcnt_d   = fill_bcnt_q;
    fill_ferr_d   = fill_ferr_q;
    fill_pf_d     = fill_pf_q;
    pf_probe_d    = pf_probe_q;
    // Recomputed every cycle: 1 when the last tag launch was the pf row and
    // an inval-match did not steal it. Only read under TAG_SRAM.
    pf_row_d      = pf_launch && !tag_match_inval;
    pf_addr_d     = pf_addr_q;
    pf_alloc      = 1'b0;
    fifo_d        = fifo_q;
    fifo_rd_d     = fifo_rd_q;
    fifo_wr_d     = fifo_wr_q;
    fifo_cnt_d    = fifo_cnt_q;
    issued_cnt_d  = issued_cnt_q;
    collect_cnt_d = collect_cnt_q;
    bfid_rpend_d  = bfid_rpend_q;
    bfid_timer_d  = bfid_timer_q;
    serve_turn_d  = serve_turn_q;
    serve_idx_d   = serve_idx_q;
    serve_addr_d  = serve_addr_q;
    serve_id_d    = serve_id_q;
    serve_len_d   = serve_len_q;
    serve_beat_d  = serve_beat_q;
    serve_intr_d  = serve_intr_q;

    mst_r_ot_d  = mst_r_ot_q;
    wr_r_pending_d = wr_r_pending_q;
    wr_b_done_d    = wr_b_done_q;
    wtrk_push      = 1'b0;
    rdtrk_push     = 1'b0;
    rdtrk_pop      = 1'b0;
    wr_posted_d    = wr_posted_q;
    wr_trk_idx_d   = wr_trk_idx_q;
    r_rdtrk_active_d = r_rdtrk_active_q;
    r_turn_d       = r_turn_q;
    state_d     = state_q;
    addr_d      = addr_q;
    id_d        = id_q;
    len_d       = len_q;
    size_d      = size_q;
    cache_d     = cache_q;
    atop_d      = atop_q;
    lock_d      = lock_q;
    burst_incr_d = burst_incr_q;
    is_write_d  = is_write_q;
    cacheable_d = cacheable_q;
    way_d       = way_q;
    line_d      = line_q;
    hit_fresh_d = hit_fresh_q;
    beat_d      = beat_q;

    l2_hit_o    = 1'b0;
    l2_miss_o   = 1'b0;
    l2_bypass_o = 1'b0;
    l2_pf_issue_o  = 1'b0;
    l2_pf_useful_o = 1'b0;
    l2_pf_drop_o   = 1'b0;
    l2_evict_valid_o = 1'b0;
    l2_evict_addr_o  = '0;
    wr_self_inval      = 1'b0;
    wr_self_inval_addr = addr_q;
    wr_inval_pend_d    = wr_inval_pend_q;
    wr_inval_addr_d    = wr_inval_addr_q;
    wu_decided_d       = wu_decided_q;
    wu_hit_d           = wu_hit_q;
    wu_way_d           = wu_way_q;
    wu_beat_d          = wu_beat_q;

    unique case (state_q)
      // ---------------- IDLE: accept AR (reads), serve a ready fill, or AW --
      S_IDLE: begin
        // Drain any late ATOP/AMO/bypass R before starting a new request —
        // but never fill beats: those are consumed by the fill collector
        // below (r.id==FILL_ID while a fill is collecting), and forwarding
        // them here would both corrupt the response stream and starve the
        // collecting entry. Tracked bypass-read beats are also excluded —
        // the M1b R arbiter forwards them (with pop bookkeeping) so the
        // FSM keeps taking new work while they drain.
        if (mst_resp_i.r_valid && !is_fill_beat && !rdtrk_head_match) begin
          slv_resp_o.r_valid = 1'b1;
          slv_resp_o.r       = mst_resp_i.r;
          mst_req_o.r_ready  = slv_req_i.r_ready;
        end else if (wr_inval_pend_q) begin
          // A deferred self-invalidation must land before any later request can
          // look up the line it covers.
          state_d = S_IDLE;
        end else if (slv_req_i.ar_valid && (serve_turn_q || !serve_pend) && !prefer_write) begin
          // Prefer reads (MLP); accept write when no AR
          slv_resp_o.ar_ready = 1'b1;
          addr_d      = slv_req_i.ar.addr;
          id_d        = slv_req_i.ar.id;
          len_d       = slv_req_i.ar.len;
          size_d      = slv_req_i.ar.size;
          cache_d     = slv_req_i.ar.cache;
          atop_d      = '0;
          // Exclusive LR (AxLOCK) must reach g6lc_axi_lrsc. Zeroing lock_d
          // here made LDEX a plain AR; STEX then saw no reservation (Variane
          // sc.d rd=1 / tohost=9) while amoadd.d ATOP still passed (AW.lock
          // was already captured). Locked AR always bypasses — a cache hit
          // would return OKAY and never arm the DRAM monitor.
          lock_d      = slv_req_i.ar.lock;
          burst_incr_d = (slv_req_i.ar.burst == axi_pkg::BURST_INCR);
          is_write_d  = 1'b0;
          cacheable_d = l2_is_cacheable(slv_req_i.ar.cache);
          beat_d      = '0;
          serve_turn_d = 1'b0;
          if (l2_is_cacheable(slv_req_i.ar.cache) && !slv_req_i.ar.lock) begin
            state_d = S_TAG;
          end else begin
            l2_bypass_o = 1'b1;
            state_d = S_BYPASS_AR;
          end
        end else if (serve_pend && !prefer_write && r_fsm_start_ok &&
                     !rdtrk_probe_match[1]) begin
          // Oldest ready fill entry gets the response channel next. Its
          // primary's id/offset come from the entry itself (complete_idx is
          // already pointed at the fifo head below). The R5 hold: a serve
          // whose id has a live bypass-read tracker entry waits for that
          // entry to pop (per-id response order), and the arbiter may hold
          // the entry one more cycle for a tracked burst.
          serve_idx_d  = fifo_q[fifo_rd_q];
          serve_addr_d = fill_addr_q[fifo_q[fifo_rd_q]];
          serve_id_d   = mshr_complete_id;
          serve_len_d  = fill_len_q[fifo_q[fifo_rd_q]];
          serve_beat_d = '0;
          serve_intr_d = 1'b0;
          // A pf fill has no primary burst: waitered pf heads start at the
          // waiter pop; the waitless case is retired inline (pf_retire).
          state_d      = head_pf ? S_SERVE_POP : S_SERVE;
        end else if (slv_req_i.aw_valid && wtrk_aw_ok) begin
          // Writes: write-through bypass (always push to memory); optional allocate
          slv_resp_o.aw_ready = 1'b1;
          addr_d      = slv_req_i.aw.addr;
          id_d        = slv_req_i.aw.id;
          len_d       = slv_req_i.aw.len;
          size_d      = slv_req_i.aw.size;
          cache_d     = slv_req_i.aw.cache;
          // Preserve ATOP/lock — dropping them turns AMOCAS into a plain store
          // and the HPDCACHE UC FSM hangs waiting for the atomic R beat.
          atop_d      = slv_req_i.aw.atop;
          lock_d      = slv_req_i.aw.lock;
          // WRITE_UPDATE merges multi-beat writes at linear INCR offsets —
          // WRAP/FIXED bursts keep the invalidate path.
          burst_incr_d = (slv_req_i.aw.burst == axi_pkg::BURST_INCR);
          is_write_d  = 1'b1;
          cacheable_d = l2_is_cacheable(slv_req_i.aw.cache);
          beat_d      = '0;
          l2_bypass_o = 1'b1;
          wr_r_pending_d = slv_req_i.aw.atop[5];
          wr_b_done_d    = 1'b0;
          // M1b: every accepted write allocates a tracker entry (AW-issue
          // order); postable writes then skip S_BYPASS_B after their last W.
          wtrk_push    = 1'b1;
          wr_trk_idx_d = wtrk_alloc_idx;
          wr_posted_d  = aw_postable;
          state_d     = S_BYPASS_AW;
        end
      end

      // ---------------- TAG lookup ----------------
      S_TAG: begin
        tag_lookup = 1'b1;
        tag_iindex = idx_of(addr_q);
        tag_ltag   = tag_of(addr_q);
        // TAG_SRAM: the launched row gates the decision. While it is low (an
        // inval-match read stole the port, or the first row after re-entry
        // has not landed) the request holds in S_TAG and re-launches; no hit/
        // miss pulse, evict offer or MSHR alloc may commit on a stale row.
        // Under TAG_SRAM=0 tag_row_valid is constant and this folds away.
        if (tag_row_valid) begin
        if((tag_hit && (|mshr_id_match)) || (!tag_hit && merge_order_block))begin
          if(serve_pend && r_fsm_start_ok && !rdtrk_probe_match[1])begin
            serve_idx_d=fifo_q[fifo_rd_q];
            serve_addr_d=fill_addr_q[fifo_q[fifo_rd_q]];
            serve_id_d=mshr_complete_id;
            serve_len_d=fill_len_q[fifo_q[fifo_rd_q]];
            serve_beat_d='0;
            serve_intr_d=1'b1;
            state_d=head_pf ? S_SERVE_POP : S_SERVE;
          end
        end else if(tag_hit)begin
          l2_hit_o = 1'b1;
          // T9h/M5: a demand hit on a PF-installed line — the tag self-clears
          // the way's pf bit on this lookup, so each prefetched line counts
          // as useful at most once.
          l2_pf_useful_o = tag_hit_pf;
          way_d    = tag_way;
          // Kick data read
          hit_fresh_d = 1'b1;
          state_d    = S_HIT_WAIT;
        end else begin
          l2_miss_o = 1'b1;
          // Victim: first invalid way (lowest index), else the per-set
          // round-robin pointer (RR_EN) or way 0 (legacy). Ways that a
          // still-in-flight fill will install for this set are deprioritized:
          // picking one would let a younger fill silently overwrite a line the
          // older fill installs afterwards, with no evict notification for it.
          begin
            way_d = victim_way;
            // Inclusive path: report replace of a valid victim line. The offer
            // re-asserts on every cycle spent in S_TAG, so withholding
            // l2_evict_ready_i simply extends the offer; the miss commit (MSHR
            // alloc + victim selection capture) waits for the accept edge,
            // which is also the edge the back-inval engine registers the
            // victim. A same-line merge needs no victim at all.
            if (!mshr_lookup_hit && tag_way_valid[way_d]) begin
              l2_evict_valid_o = 1'b1;
              l2_evict_addr_o  = {
                tag_probe_tag,
                idx_of(addr_q),
                {OFF_BITS{1'b0}}
              };
            end
            // A same-line merge needs no victim way and no evict — only a
            // fresh alloc is gated on way_ok and the evict handshake. R1
            // (M1b): a miss whose line carries a write-tracker entry must
            // not commit either — a posted write's B has not landed, so a
            // fill AR now could return pre-write memory (AXI does not order
            // an AR against an earlier AW to the same address). Hits are
            // served (merged data); the hold retries when the entry pops.
            if (mshr_ready && !wtrk_line0_match &&
                (mshr_lookup_hit ||
                 (way_ok && (!tag_way_valid[way_d] || l2_evict_ready_i)))) begin
              mshr_alloc = 1'b1;
              // A demand merging onto an in-flight PF fill is a useful
              // prefetch — it saves exactly the fill latency it waited for.
              if (mshr_lookup_hit)
                l2_pf_useful_o = fill_pf_q[mshr_lookup_idx];
              if (!mshr_lookup_hit) begin
                // Fresh miss: park the entry, queue a background fill and
                // return to S_IDLE — the pipeline takes the next request
                // while the fill engine fetches the line (MLP).
                fifo_d[fifo_wr_q]            = mshr_alloc_idx;
                fifo_wr_d                    = fifo_inc(fifo_wr_q);
                fifo_cnt_d                   = fifo_cnt_q + 1'b1;
                fill_act_d[mshr_alloc_idx]   = 1'b1;
                fill_state_d[mshr_alloc_idx] = F_QUEUED;
                fill_kill_d[mshr_alloc_idx]  = 1'b0;
                fill_addr_d[mshr_alloc_idx]  = addr_q;
                fill_way_d[mshr_alloc_idx]   = way_d;
                fill_len_d[mshr_alloc_idx]   = len_q;
                fill_bcnt_d[mshr_alloc_idx]  = '0;
                fill_ferr_d[mshr_alloc_idx]  = axi_pkg::RESP_OKAY;
                fill_pf_d[mshr_alloc_idx]    = 1'b0;
              end
              state_d = S_IDLE;
            end else if (serve_pend && r_fsm_start_ok &&
                         !rdtrk_probe_match[1]) begin
              // Deadlock break: this request cannot commit (MSHR full, or no
              // evictable way), and MSHR entries only free through the serve
              // path — which needs this FSM. Interrupt: drain the oldest
              // ready entry on the dedicated serve regs (the captive request
              // stays in addr_q & friends), then return to S_TAG to retry.
              serve_idx_d  = fifo_q[fifo_rd_q];
              serve_addr_d = fill_addr_q[fifo_q[fifo_rd_q]];
              serve_id_d   = mshr_complete_id;
              serve_len_d  = fill_len_q[fifo_q[fifo_rd_q]];
              serve_beat_d = '0;
              serve_intr_d = 1'b1;
              state_d      = head_pf ? S_SERVE_POP : S_SERVE;
            end
            // else stall in S_TAG until MSHR free / evict accept / way frees
          end
        end
        end
      end

      // ---------------- HIT: wait 1-cycle SRAM ----------------
      S_HIT_WAIT: begin
        // R5 + arbiter: enter the response channel only when it is free for
        // a new burst and no tracked bypass read carries this id.
        if (r_fsm_start_ok && !rdtrk_probe_match[0]) state_d = S_HIT_RESP;
        // Latch the port-A result on the entry cycle only — a multi-cycle
        // R5 hold would otherwise re-sample a port that has moved on.
        if (hit_fresh_q) line_d = data_a_rdata;
        hit_fresh_d = 1'b0;
      end

      S_HIT_RESP: begin
        // Return beats from captured line starting at the AR address offset
        // (beat_base), not always at line beat 0.
        slv_resp_o.r_valid = 1'b1;
        slv_resp_o.r.id    = id_q;
        slv_resp_o.r.resp  = axi_pkg::RESP_OKAY;
        slv_resp_o.r.last  = (beat_q == len_q);
        slv_resp_o.r.data  = line_q[beat_idx*AXI_DATA_WIDTH +: AXI_DATA_WIDTH];
        if (slv_req_i.r_ready) begin
          if (beat_q == len_q) begin
            beat_d  = '0;
            state_d = S_IDLE;
          end else begin
            beat_d = beat_q + 1'b1;
          end
        end
      end

      // ---------------- SERVE: drain a ready fill entry ----------------
      // Serve one response burst (primary or a popped waiter) from the fill
      // entry's line buffer on the dedicated serve regs — addr_q & friends
      // may be holding a request stalled in S_TAG (interrupt case). A failed
      // or killed fill still drains its beats and serves the accumulated
      // error resp to every attached waiter.
      S_SERVE: begin
        slv_resp_o.r_valid = 1'b1;
        slv_resp_o.r.id    = serve_id_q;
        slv_resp_o.r.resp  = (fill_ferr_q[serve_idx_q] != axi_pkg::RESP_OKAY)
                             ? fill_ferr_q[serve_idx_q] : axi_pkg::RESP_OKAY;
        slv_resp_o.r.last  = (serve_beat_q == serve_len_q);
        slv_resp_o.r.data  =
          fill_buf_q[serve_idx_q][serve_bidx*AXI_DATA_WIDTH +: AXI_DATA_WIDTH];
        if (slv_req_i.r_ready) begin
          if (serve_beat_q == serve_len_q) begin
            serve_beat_d = '0;
            // Serve any same-line reader that attached before retiring the
            // MSHR entry; the entry must stay valid until then.
            if (mshr_waiter_valid) begin
              state_d = S_SERVE_POP;
            end else begin
              mshr_complete = 1'b1;
              fill_act_d[serve_idx_q] = 1'b0;
              // Retire the issue-order fifo head: every counter is a
              // distance from rd, so all of them shift down by one.
              fifo_rd_d     = fifo_inc(fifo_rd_q);
              fifo_cnt_d    = fifo_cnt_q - 1'b1;
              issued_cnt_d  = issued_cnt_q - 1'b1;
              collect_cnt_d = collect_cnt_q - 1'b1;
              serve_turn_d  = 1'b1;
              serve_intr_d  = 1'b0;
              // An interrupted S_TAG request retries its lookup next.
              state_d       = serve_intr_q ? ((cacheable_q && !lock_q) ? S_TAG : S_BYPASS_AR) : S_IDLE;
            end
          end else begin
            serve_beat_d = serve_beat_q + 1'b1;
          end
        end
      end

      // Pop the next merged waiter and re-serve it from the filled line.
      // R5: hold the pop while the waiter's id is carried by a live tracked
      // bypass read, and while the R channel is arbitrated to memory-side
      // beats — the waiter's burst must not interleave or precede them.
      S_SERVE_POP: begin
        if (r_fsm_start_ok && !rdtrk_probe_match[2]) begin
          mshr_waiter_pop = 1'b1;
          serve_id_d      = mshr_waiter_id;
          // Same line as the primary: keep the line bits, swap in the offset.
          serve_addr_d    = {serve_addr_q[AXI_ADDR_WIDTH-1:OFF_BITS], waiter_off};
          serve_len_d     = waiter_len;
          serve_beat_d    = '0;
          state_d         = S_SERVE;
        end
      end

      // ---------------- Non-cacheable / write bypass ----------------
      S_BYPASS_AR: begin
        // Drive captured fields. Copying live slv.ar a cycle after the
        // handshake drops AR.lock (HPDCACHE already deasserted the beat).
        // FILL_ID exclusion: a bypass under the reserved fill id can only
        // issue while no fill is outstanding — its R beats would otherwise
        // interleave with fill beats and alias into the collector.
        mst_req_o.ar_valid = bypass_ar_offer;
        mst_req_o.ar.addr  = addr_q;
        mst_req_o.ar.id    = id_q;
        mst_req_o.ar.len   = len_q;
        mst_req_o.ar.size  = size_q;
        mst_req_o.ar.burst = axi_pkg::BURST_INCR;
        mst_req_o.ar.cache = cache_q;
        mst_req_o.ar.lock  = lock_q;
        mst_req_o.ar.prot  = 3'b000;
        if (mst_req_o.ar_valid && mst_resp_i.ar_ready) begin
          if (id_q == FILL_ID) bfid_rpend_d = 1'b1;
          if (POSTED_WRITES && (id_q != FILL_ID) && !rdtrk_full &&
              !wtrk_need_r_match) begin
            // Tracked bypass read: the read tracker + R arbiter return the
            // beats while the FSM takes the next request. FILL_ID reads,
            // a full tracker, and reads sharing an ATOP-load write's id
            // keep the blocking S_BYPASS_R trail.
            rdtrk_push = 1'b1;
            state_d = S_IDLE;
          end else begin
            state_d = S_BYPASS_R;
          end
        end
        else if((|mshr_id_match) && serve_pend && r_fsm_start_ok &&
                !rdtrk_probe_match[1])begin
          serve_idx_d=fifo_q[fifo_rd_q];
          serve_addr_d=fill_addr_q[fifo_q[fifo_rd_q]];
          serve_id_d=mshr_complete_id;
          serve_len_d=fill_len_q[fifo_q[fifo_rd_q]];
          serve_beat_d='0;
          serve_intr_d=1'b1;
          state_d=head_pf ? S_SERVE_POP : S_SERVE;
        end
      end

      S_BYPASS_R: begin
        // Forward only this transaction's beats: fill beats (id==FILL_ID) can
        // interleave on the R channel and belong to the collector below.
        // A same-id beat claimed by the read tracker belongs to the older
        // tracked burst (per-id order) — the arbiter forwards it and pops
        // its entry; this read's own beats arrive after that pop.
        if (mst_resp_i.r_valid && mst_resp_i.r.id == id_q && !rdtrk_head_match) begin
          slv_resp_o.r_valid = 1'b1;
          slv_resp_o.r       = mst_resp_i.r;
          mst_req_o.r_ready  = slv_req_i.r_ready;
          if (slv_req_i.r_ready && mst_resp_i.r.last) state_d = S_IDLE;
        end
      end

      S_BYPASS_AW: begin
        // FILL_ID exclusion mirrors S_BYPASS_AR: an AMO/ATOP under the fill id
        // injects R beats that would alias into an in-flight fill collector.
        mst_req_o.aw_valid = !(id_q == FILL_ID && (fill_out || fill_ar_hold_q));
        mst_req_o.aw.addr  = addr_q;
        // T9d/M1d: a posted write goes downstream on the reserved WR_ID —
        // every posted write shares one id, so memory applies them in
        // acceptance (merge) order and same-line posted writes never need
        // the R2 hold. Blocking writes keep their original id.
        mst_req_o.aw.id    = (POSTED_WRITES && wr_posted_q) ? WR_ID : id_q;
        mst_req_o.aw.len   = len_q;
        mst_req_o.aw.size  = size_q;
        mst_req_o.aw.burst = axi_pkg::BURST_INCR;
        mst_req_o.aw.cache = cache_q;
        mst_req_o.aw.atop  = atop_q;
        mst_req_o.aw.lock  = lock_q;
        // Drop any L2 copy of this line — except under WRITE_UPDATE, where a
        // confirmed resident hit keeps the line and merges the W beats.
        wr_self_inval      = 1'b1;
        wr_self_inval_addr = addr_q;
        // Write-update decision, first bypass cycle only: the row for this
        // set was launched at the S_IDLE accept edge (see tag_launch below),
        // so the compare resolves here. An eligible write that finds its
        // line resident becomes wu_hit_q — the tag clear is suppressed and
        // the W beats merge in place. Anything else keeps the
        // invalidate-and-kill path. This is a silent probe of the tag: no
        // l2_hit_o/l2_miss_o pulse is emitted for it.
        if (WRITE_UPDATE && !wu_decided_q) begin
          wu_decided_d = 1'b1;
          if (wu_eligible) begin
            tag_lookup = 1'b1;
            wu_hit_d   = tag_row_valid && tag_hit;
            wu_way_d   = tag_way;
          end
        end
        // ATOP/AMO may already be fetching old data — never block R.
        if(wr_r_pending_q && mst_resp_i.r_valid && mst_resp_i.r.id==id_q && !is_fill_beat)begin
          slv_resp_o.r_valid = 1'b1;
          slv_resp_o.r       = mst_resp_i.r;
          mst_req_o.r_ready  = slv_req_i.r_ready;
        end
        if (mst_req_o.aw_valid && mst_resp_i.aw_ready) begin
          if(id_q==FILL_ID)bfid_rpend_d=atop_q[5];
          state_d = S_BYPASS_W;
        end
      end

      S_BYPASS_W: begin
        slv_resp_o.w_ready = mst_resp_i.w_ready;
        mst_req_o.w_valid  = slv_req_i.w_valid;
        mst_req_o.w        = slv_req_i.w;
        // Keep self-inval asserted through W so multi-beat writes still snoop
        wr_self_inval      = 1'b1;
        wr_self_inval_addr = addr_q;
        // A write-update hit merges each forwarded beat into the resident
        // line (the W channel is still forwarded unchanged to memory).
        if (wu_merge_wr) wu_beat_d = wu_beat_q + 1'b1;
        // Forward ATOP load/compare R beats while W is in flight
        if(wr_r_pending_q && mst_resp_i.r_valid && mst_resp_i.r.id==id_q && !is_fill_beat)begin
          slv_resp_o.r_valid = 1'b1;
          slv_resp_o.r       = mst_resp_i.r;
          mst_req_o.r_ready  = slv_req_i.r_ready;
        end
        if (slv_req_i.w_valid && mst_resp_i.w_ready && slv_req_i.w.last)
          // A posted write is done here: its tracker entry routes the later
          // B through the uniform slave B channel (ordering rule 4).
          state_d = (POSTED_WRITES && wr_posted_q) ? S_IDLE : S_BYPASS_B;
      end

      S_BYPASS_B: begin
        // Under POSTED_WRITES the write tracker owns both B channels
        // (uniform routing); this state then only waits for "my" entry to
        // drain and forwards any ATOP R as before.
        if (!POSTED_WRITES) begin
          slv_resp_o.b_valid=mst_resp_i.b_valid && (mst_resp_i.b.id==id_q) && !wr_b_done_q;
          slv_resp_o.b=mst_resp_i.b;
          mst_req_o.b_ready=slv_req_i.b_ready && (mst_resp_i.b.id==id_q) && !wr_b_done_q;
        end
        // AXI ATOP (AMOCAS/AMOLOAD/…) returns old data on R with the AW id.
        // Must forward and accept R here — if we leave it unabsorbed,
        // axi_riscv_amos stays in SEND_R with mst_r_ready=0 and would orphan
        // the next miss-fill at axi2mem.
        if(wr_r_pending_q && mst_resp_i.r_valid && mst_resp_i.r.id==id_q && !is_fill_beat)begin
          slv_resp_o.r_valid = 1'b1;
          slv_resp_o.r       = mst_resp_i.r;
          mst_req_o.r_ready  = slv_req_i.r_ready;
        end
        if(!POSTED_WRITES && mst_resp_i.b_valid && mst_resp_i.b.id==id_q && slv_req_i.b_ready && !wr_b_done_q)
          wr_b_done_d=1'b1;
      end

      default: state_d = S_IDLE;
    endcase

    if((state_q==S_BYPASS_AW || state_q==S_BYPASS_W || state_q==S_BYPASS_B) &&
       wr_r_pending_q && mst_resp_i.r_valid && mst_resp_i.r.id==id_q &&
       !is_fill_beat && slv_req_i.r_ready && mst_resp_i.r.last)
      wr_r_pending_d=1'b0;
    if(state_q==S_BYPASS_B && wr_b_done_d && !wr_r_pending_d)state_d=S_IDLE;
    // Write-update state lives only inside one bypassed write.
    if (state_d == S_IDLE) begin
      wu_decided_d = 1'b0;
      wu_hit_d     = 1'b0;
      wu_beat_d    = '0;
    end

    // ---- Fill collector: drain FILL_ID beats into per-entry line buffers ----
    // All fills issue under FILL_ID, so AXI same-ID ordering guarantees their
    // bursts return in issue order with contiguous beats — fifo position
    // rd+collect_cnt always names the entry the current beat belongs to. A
    // spurious early r_last (axi_riscv_amos injection can share an id) is
    // discarded unless it lands on the final beat position.
    if (collect_active && mst_resp_i.r_valid && mst_resp_i.r.id == FILL_ID) begin
      mst_req_o.r_ready = 1'b1;
      // A last arriving before the final beat position is spurious (amos
      // injection can share an id): discard it and keep collecting. A last at
      // or past the final position terminates the fill.
      if (!(mst_resp_i.r.last &&
            (fill_bcnt_q[collect_idx] < (BEAT_IDX_W + 1)'(BEATS - 1)))) begin
        if (fill_bcnt_q[collect_idx] < (BEAT_IDX_W + 1)'(BEATS)) begin
          fill_buf_d[collect_idx][fill_bcnt_q[collect_idx]*AXI_DATA_WIDTH +: AXI_DATA_WIDTH]
            = mst_resp_i.r.data;
          if (mst_resp_i.r.resp != axi_pkg::RESP_OKAY &&
              fill_ferr_q[collect_idx] == axi_pkg::RESP_OKAY)
            fill_ferr_d[collect_idx] = mst_resp_i.r.resp;
          fill_bcnt_d[collect_idx] = fill_bcnt_q[collect_idx] + 1'b1;
        end
        if (mst_resp_i.r.last) begin
          fill_state_d[collect_idx] = F_DONE;
          collect_cnt_d             = collect_cnt_d + 1'b1;
        end
      end
    end

    // ---- Fill-issue engine: oldest queued entry drives mst.ar under FILL_ID
    // The AR channel is shared with the bypass path (S_BYPASS_AR has it when
    // the FSM is there) and a live FILL_ID bypass trail holds fills off.
    if (fill_ar_offer) begin
      mst_req_o.ar_valid = 1'b1;
      mst_req_o.ar.id    = FILL_ID;
      mst_req_o.ar.addr  = line_align(fill_addr_q[issue_idx]);
      mst_req_o.ar.len   = axi_pkg::len_t'(BEATS - 1);
      mst_req_o.ar.size  = axi_pkg::size_t'($clog2(AXI_DATA_WIDTH/8));
      mst_req_o.ar.burst = axi_pkg::BURST_INCR;
      mst_req_o.ar.cache = 4'b1111;
      mst_req_o.ar.prot  = 3'b000;
      if (mst_resp_i.ar_ready) begin
        fill_state_d[issue_idx] = F_FILLING;
        issued_cnt_d            = issued_cnt_d + 1'b1;
      end
    end
    fill_ar_hold_d = fill_ar_offer && !mst_resp_i.ar_ready;

    // ---- Install engine: one F_DONE entry per cycle gets the write port ----
    // A killed fill (invalidated while in flight) or a failed fill installs
    // nothing — a poisoned "valid" line would serve error/stale data to every
    // later read silently. Both still become servable so attached waiters
    // drain, then the entry frees.
    if (inst_vld) begin
      if (install_discard) begin
        fill_state_d[inst_idx] = F_READY;
      end else begin
        // wu_install_stall holds off an install that would claim the merge's
        // way mid-write — see the WRITE_UPDATE block. The data-bank request
        // is gated the same way, so no port attempt is made while stalled.
        tag_write  = !bank_conflict && !wu_install_stall;
        tag_windex = idx_of(fill_addr_q[inst_idx]);
        tag_wway   = fill_way_q[inst_idx];
        tag_wtag   = tag_of(fill_addr_q[inst_idx]);
        tag_wvalid = 1'b1;


        if (!bank_conflict && !wu_install_stall) begin
          fill_state_d[inst_idx] = F_READY;
          // RR pointer tracks the last-installed way (advances past it).
          rr_adv = RR_EN;
        end
      end
    end

    // ---- Kill-on-invalidation: fills matching an accepted snoop stop
    // merging, skip install, and drain+discard. Waiters that attached before
    // the invalidation are ordered before it and may still be served; F_READY
    // entries are killed too because a merge attaching after the inval is
    // ordered after it and must not be served the stale pre-inval line.
    // Defer a self-invalidation the external snoop displaced, and retire it on
    // the first cycle the match port is free. The arm taps the raw write
    // stream rather than the WU-suppressed self_inval_req: a write-update
    // hit colliding with a back-inval still retires a match for its line —
    // conservatively clearing the merged line so the fill-kill can never be
    // starved for the whole AW/W window.
    if ((wr_self_inval | wr_inval_pend_q) && l2_back_inval_valid_i) begin
      wr_inval_pend_d = 1'b1;
      wr_inval_addr_d = self_inval_addr;
    end else if (wr_inval_pend_q) begin
      wr_inval_pend_d = 1'b0;
    end

    if (kill_match) begin
      for (int unsigned e = 0; e < MSHR_DEPTH; e++) begin
        if (fill_act_q[e] &&
            (line_align(fill_addr_q[e]) ==
             AXI_ADDR_WIDTH'({tag_match_tag, tag_match_index, {OFF_BITS{1'b0}}})))
          fill_kill_d[e] = 1'b1;
      end
    end

    // ---- FILL_ID bypass trail: holds the fill-issue engine off until the
    // bypass's own response (and any late AMO/ATOP R straggler) has drained.
    if (mst_resp_i.r_valid && (mst_resp_i.r.id == FILL_ID) && !collect_active &&
        mst_req_o.r_ready) begin
      bfid_timer_d = BFID_SETTLE[5:0];
      if (mst_resp_i.r.last) bfid_rpend_d = 1'b0;
    end
    if (mst_resp_i.b_valid && (mst_resp_i.b.id == FILL_ID) &&
        mst_req_o.b_ready) begin
      bfid_timer_d = BFID_SETTLE[5:0];
      // Non-ATOP writes and ATOP-stores return no R trail; ATOP-loads keep
      // rpend until their R's last beat clears it above.
      if(!atop_q[5]) bfid_rpend_d = 1'b0;
    end
    if (bfid_timer_q != '0) bfid_timer_d = bfid_timer_q - 1'b1;

    // ---- Master R drain (must run after case so it can override r_ready) ----
    // Track bypass AR→R outstanding so we never leave the DRAM R channel
    // blocked: axi2mem stays in READ with r_valid && !r_ready until r_last is
    // taken. Fill ARs are tracked by issued/collect counters instead.
    mst_r_ot_d = mst_r_ot_q;
    // A tracked bypass read does not need the blocking drain flag — the
    // read tracker owns its R return and pops on the last beat.
    if (mst_req_o.ar_valid && mst_resp_i.ar_ready && mst_req_o.ar.id != FILL_ID &&
        !rdtrk_push) begin
      mst_r_ot_d = 1'b1;
    end
    if (mst_r_ot_q) begin
      // Keep accepting R until last beat even if FSM left S_BYPASS_R.
      // Never eat a tracked burst's beats: the arbiter forwards those.
      if (state_q != S_BYPASS_R && !rdtrk_head_match) mst_req_o.r_ready = 1'b1;
      if (mst_resp_i.r_valid && mst_req_o.r_ready && mst_resp_i.r.last &&
          mst_resp_i.r.id == id_q) begin
        mst_r_ot_d = 1'b0;
      end
    end
    // Safety: ATOP/AMO R can arrive after the write-bypass FSM has already
    // returned to IDLE (amos injects R after B). Forward it to the slave so
    // (1) HPDCACHE gets the atomic old-data beat and (2) amos leaves SEND_R
    // (which holds mst_r_ready=0 and would orphan the next miss-fill at
    // axi2mem). If the slave is not ready, keep the beat pending — do not
    // silently drop ATOP R. Fill beats are never forwarded here, and
    // tracked bypass beats take the arbiter path.
    if (state_q == S_IDLE && mst_resp_i.r_valid && !mst_r_ot_q && !is_fill_beat &&
        !rdtrk_head_match) begin
      slv_resp_o.r_valid = 1'b1;
      slv_resp_o.r       = mst_resp_i.r;
      mst_req_o.r_ready  = slv_req_i.r_ready;
    end

    // ---- M1b posted-write B routing + bypass-read R arbiter ----
    // Everything in this block folds away under POSTED_WRITES=0: the tracker
    // tie-offs leave the B/R channels exactly on the M1a paths.
    if (POSTED_WRITES) begin
      // Uniform slave B channel (ordering rule 4): the tracker presents the
      // oldest entry whose B has arrived; pop on slave acceptance. The
      // memory B channel absorbs into the matching unserved entry — B order
      // per id is an AXI guarantee, so oldest-match is exact.
      slv_resp_o.b_valid = wtrk_sb_valid;
      slv_resp_o.b.id    = wtrk_sb_id;
      slv_resp_o.b.resp  = wtrk_sb_resp;
      slv_resp_o.b.user  = wtrk_sb_user;
      mst_req_o.b_ready  = mst_resp_i.b_valid && wtrk_m_match;
      // A blocking write's wait ends when its own tracker entry drains.
      if (wtrk_pop && (wtrk_pop_idx == wr_trk_idx_q) && !wr_posted_q) begin
        wr_b_done_d = 1'b1;
        if (!atop_q[5]) bfid_rpend_d = 1'b0;
      end
      // Bypass-read arbiter: an in-progress tracked burst owns the slave R
      // channel through last; new bursts alternate with FSM-internal bursts
      // on r_turn_q (rule 5/6). FSM channel entry is gated by
      // r_fsm_start_ok, so a tracked burst is never interleaved.
      if (rdtrk_grant) begin
        slv_resp_o.r_valid = 1'b1;
        slv_resp_o.r       = mst_resp_i.r;
        mst_req_o.r_ready  = slv_req_i.r_ready;
        if (slv_req_i.r_ready) begin
          r_rdtrk_active_d = !mst_resp_i.r.last;
          if (mst_resp_i.r.last) begin
            rdtrk_pop = 1'b1;
            r_turn_d  = 1'b0;   // next new-burst grant favors the FSM
          end
        end
      end
      // Internal-burst completions hand the next grant to memory-side beats.
      if ((state_q == S_HIT_RESP) && slv_req_i.r_ready && (beat_q == len_q))
        r_turn_d = 1'b1;
      if ((state_q == S_SERVE) && slv_req_i.r_ready &&
          (serve_beat_q == serve_len_q))
        r_turn_d = 1'b1;
      // A completed blocking-path read burst counts as a memory-side burst.
      if ((state_q == S_BYPASS_R) && mst_resp_i.r_valid &&
          mst_req_o.r_ready && mst_resp_i.r.last)
        r_turn_d = 1'b0;
    end

    // ---- T9h/M5 prefetch admission (runs after the case so the demand
    // FSM's final state_d is visible; the pf probes mux tag/MSHR/tracker
    // ports only on cycles the demand path does not own them) ----
    if (pf_capture) begin
      pf_probe_d = 1'b1;
      pf_addr_d  = pf_cand_line;
    end
    if (pf_probe_fire) begin
      // Silent probe of the candidate's set/tag — no l2_hit_o/l2_miss_o
      // pulse. line0/MSHR lookup inputs are already muxed to pf_addr_q.
      tag_lookup = 1'b1;
      tag_iindex = idx_of(pf_addr_q);
      tag_ltag   = tag_of(pf_addr_q);
      if (!tag_hit && !mshr_lookup_hit && !wtrk_line0_match &&
          (mshr_count < (MSHR_W + 1)'(MSHR_DEPTH - PF_MSHR_RESERVE)) &&
          pf_way_ok) begin
        // Commit: pf-flagged fill, no waiter, installs like a demand fill.
        pf_alloc                     = 1'b1;
        mshr_alloc                   = 1'b1;
        mshr_alloc_meta              = '0;
        fifo_d[fifo_wr_q]            = mshr_alloc_idx;
        fifo_wr_d                    = fifo_inc(fifo_wr_q);
        fifo_cnt_d                   = fifo_cnt_q + 1'b1;
        fill_act_d[mshr_alloc_idx]   = 1'b1;
        fill_state_d[mshr_alloc_idx] = F_QUEUED;
        fill_kill_d[mshr_alloc_idx]  = 1'b0;
        fill_addr_d[mshr_alloc_idx]  = pf_addr_q;
        fill_way_d[mshr_alloc_idx]   = pf_way;
        fill_len_d[mshr_alloc_idx]   = '0;
        fill_bcnt_d[mshr_alloc_idx]  = '0;
        fill_ferr_d[mshr_alloc_idx]  = axi_pkg::RESP_OKAY;
        fill_pf_d[mshr_alloc_idx]    = 1'b1;
        l2_pf_issue_o                = 1'b1;
      end else begin
        l2_pf_drop_o = 1'b1;
      end
      pf_probe_d = 1'b0;
    end

    // A served-out pf head carrying no waiters frees itself — no slave
    // burst, no serve regs. !mshr_alloc: a same-cycle waiter attach (an
    // S_TAG merge landing on this entry) or a pf commit wins, and the
    // retire retries next cycle — the head then drains via the serve path.
    if (pf_retire && !mshr_alloc) begin
      mshr_complete                 = 1'b1;
      fill_act_d[fifo_q[fifo_rd_q]] = 1'b0;
      fifo_rd_d                     = fifo_inc(fifo_rd_q);
      // Accumulate on _d, not _q: this block runs after the collector and
      // issue engine, whose same-cycle +1s (an AR issue or a last-beat
      // collect landing under a pf head retire) must survive.
      fifo_cnt_d                    = fifo_cnt_d - 1'b1;
      issued_cnt_d                  = issued_cnt_d - 1'b1;
      collect_cnt_d                 = collect_cnt_d - 1'b1;
    end

    // Launched tag-row read (TAG_SRAM): evaluated after every state_d/addr_d
    // assignment so it covers the S_IDLE accept edge, each held S_TAG cycle
    // (relaunch after an inval-match port steal) and the S_SERVE interrupt
    // return — the row is therefore presented on the first S_TAG cycle with
    // no added wait state. WRITE_UPDATE also launches on the write-accept
    // edge so the write-update decision in the first S_BYPASS_AW cycle sees
    // the row; an inval-match steal reports !row_valid and the write
    // conservatively invalidates. Under TAG_SRAM=0 the tag module ignores
    // this. T9h/M5: a prefetch candidate row launch takes the port only on
    // cycles the demand path did not claim it (pf_launch_ok above).
    tag_launch       = (state_d == S_TAG) ||
                       (WRITE_UPDATE && state_q == S_IDLE && state_d == S_BYPASS_AW) ||
                       pf_launch;
    tag_launch_index = pf_launch ? idx_of(pf_launch_addr) : idx_of(addr_d);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= S_IDLE;
      addr_q      <= '0;
      id_q        <= '0;
      len_q       <= '0;
      size_q      <= '0;
      cache_q     <= '0;
      atop_q      <= '0;
      lock_q      <= 1'b0;
      burst_incr_q <= 1'b0;
      is_write_q  <= 1'b0;
      cacheable_q <= 1'b0;
      way_q       <= '0;
      line_q      <= '0;
      hit_fresh_q <= 1'b0;
      beat_q      <= '0;
      mst_r_ot_q  <= 1'b0;
      wr_r_pending_q <= 1'b0;
      wr_b_done_q    <= 1'b0;
      wr_posted_q    <= 1'b0;
      wr_trk_idx_q   <= '0;
      r_rdtrk_active_q <= 1'b0;
      r_turn_q       <= 1'b0;
      wr_inval_pend_q <= 1'b0;
      wr_inval_addr_q <= '0;
      wu_decided_q    <= 1'b0;
      wu_hit_q        <= 1'b0;
      wu_way_q        <= '0;
      wu_beat_q       <= '0;
      serve_turn_q <= 1'b0;
      serve_idx_q <= '0;
      serve_addr_q <= '0;
      serve_id_q   <= '0;
      serve_len_q  <= '0;
      serve_beat_q <= '0;
      serve_intr_q <= 1'b0;
      fill_act_q  <= '0;
      fill_kill_q <= '0;
      fill_pf_q   <= '0;
      pf_probe_q  <= 1'b0;
      pf_row_q    <= 1'b0;
      pf_addr_q   <= '0;
      fifo_rd_q   <= '0;
      fifo_wr_q   <= '0;
      fifo_cnt_q  <= '0;
      issued_cnt_q  <= '0;
      collect_cnt_q <= '0;
      bfid_rpend_q  <= 1'b0;
      bfid_timer_q  <= '0;
      fill_ar_hold_q <= 1'b0;
      for (int unsigned e = 0; e < MSHR_DEPTH; e++) begin
        fill_state_q[e] <= F_QUEUED;
        fill_addr_q[e]  <= '0;
        fill_way_q[e]   <= '0;
        fill_len_q[e]   <= '0;
        fill_buf_q[e]   <= '0;
        fill_bcnt_q[e]  <= '0;
        fill_ferr_q[e]  <= axi_pkg::RESP_OKAY;
        fifo_q[e]       <= '0;
      end
    end else begin
      state_q     <= state_d;
      addr_q      <= addr_d;
      id_q        <= id_d;
      len_q       <= len_d;
      size_q      <= size_d;
      cache_q     <= cache_d;
      atop_q      <= atop_d;
      lock_q      <= lock_d;
      burst_incr_q <= burst_incr_d;
      is_write_q  <= is_write_d;
      cacheable_q <= cacheable_d;
      way_q       <= way_d;
      line_q      <= line_d;
      hit_fresh_q <= hit_fresh_d;
      beat_q      <= beat_d;
      mst_r_ot_q  <= mst_r_ot_d;
      wr_r_pending_q <= wr_r_pending_d;
      wr_b_done_q    <= wr_b_done_d;
      wr_posted_q    <= wr_posted_d;
      wr_trk_idx_q   <= wr_trk_idx_d;
      r_rdtrk_active_q <= r_rdtrk_active_d;
      r_turn_q       <= r_turn_d;
      wr_inval_pend_q <= wr_inval_pend_d;
      wr_inval_addr_q <= wr_inval_addr_d;
      wu_decided_q    <= wu_decided_d;
      wu_hit_q        <= wu_hit_d;
      wu_way_q        <= wu_way_d;
      wu_beat_q       <= wu_beat_d;
      serve_turn_q <= serve_turn_d;
      serve_idx_q <= serve_idx_d;
      serve_addr_q <= serve_addr_d;
      serve_id_q   <= serve_id_d;
      serve_len_q  <= serve_len_d;
      serve_beat_q <= serve_beat_d;
      serve_intr_q <= serve_intr_d;
      fill_act_q  <= fill_act_d;
      fill_kill_q <= fill_kill_d;
      fill_pf_q   <= fill_pf_d;
      pf_probe_q  <= pf_probe_d;
      pf_row_q    <= pf_row_d;
      pf_addr_q   <= pf_addr_d;
      fifo_rd_q   <= fifo_rd_d;
      fifo_wr_q   <= fifo_wr_d;
      fifo_cnt_q  <= fifo_cnt_d;
      issued_cnt_q  <= issued_cnt_d;
      collect_cnt_q <= collect_cnt_d;
      bfid_rpend_q  <= bfid_rpend_d;
      bfid_timer_q  <= bfid_timer_d;
      fill_ar_hold_q <= fill_ar_hold_d;
      for (int unsigned e = 0; e < MSHR_DEPTH; e++) begin
        fill_state_q[e] <= fill_state_d[e];
        fill_addr_q[e]  <= fill_addr_d[e];
        fill_way_q[e]   <= fill_way_d[e];
        fill_len_q[e]   <= fill_len_d[e];
        fill_buf_q[e]   <= fill_buf_d[e];
        fill_bcnt_q[e]  <= fill_bcnt_d[e];
        fill_ferr_q[e]  <= fill_ferr_d[e];
        fifo_q[e]       <= fifo_d[e];
      end
    end
  end

  // Optional per-set round-robin victim state (RR_EN) at the tc_sram seam.
  // Read on cacheable AR acceptance, available in S_TAG with no added stage.
  // Invalid-first installs initialize each set before an all-valid lookup;
  // reset clears tags, so stale SRAM bits cannot select a valid victim.
  // RR_EN=0 elaborates no metadata RAM; off-path equivalence is a separate gate.
  if (RR_EN) begin : gen_rr
    logic read_req, do_write;
    logic [IDX_BITS-1:0] ram_addr;
    logic [WAY_W-1:0] next_way, wr_way;
    // One port serves both the lookup read and the install update. The read
    // belongs to the request that is being accepted this cycle and cannot be
    // repeated, so it takes the port; a colliding update is held and retired on
    // the first free cycle. A later install overwrites a held one because the
    // pointer means "past the way installed most recently".
    logic rr_pend_q, rr_pend_d;
    logic [IDX_BITS-1:0] rr_pend_idx_q, rr_pend_idx_d;
    logic [WAY_W-1:0] rr_pend_way_q, rr_pend_way_d;
    assign read_req = slv_req_i.ar_valid && slv_resp_o.ar_ready &&
                      l2_is_cacheable(slv_req_i.ar.cache) && !slv_req_i.ar.lock;
    assign next_way = (tag_wway == WAY_W'(SET_ASSOC - 1)) ? '0 : tag_wway + 1'b1;
    assign do_write = (rr_adv || rr_pend_q) && !read_req;
    assign ram_addr = read_req ? idx_of(slv_req_i.ar.addr)
                               : (rr_adv ? tag_windex : rr_pend_idx_q);
    assign wr_way   = rr_adv ? next_way : rr_pend_way_q;
    always_comb begin
      rr_pend_d     = rr_pend_q;
      rr_pend_idx_d = rr_pend_idx_q;
      rr_pend_way_d = rr_pend_way_q;
      if (rr_adv && read_req) begin
        rr_pend_d     = 1'b1;
        rr_pend_idx_d = tag_windex;
        rr_pend_way_d = next_way;
      end else if (rr_pend_q && !read_req) begin
        rr_pend_d = 1'b0;
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        rr_pend_q     <= 1'b0;
        rr_pend_idx_q <= '0;
        rr_pend_way_q <= '0;
      end else begin
        rr_pend_q     <= rr_pend_d;
        rr_pend_idx_q <= rr_pend_idx_d;
        rr_pend_way_q <= rr_pend_way_d;
      end
    end
    tc_sram #(
        .NumWords(NUM_SETS), .DataWidth(WAY_W), .ByteWidth(WAY_W),
        .NumPorts(1), .Latency(1), .SimInit("none")
    ) i_metadata (
        .clk_i, .rst_ni,
        .req_i(rst_ni && (read_req || do_write)), .we_i(do_write),
        .addr_i(ram_addr), .wdata_i(wr_way), .be_i(1'b1), .rdata_o(rr_victim_way)
    );
  end else begin : gen_no_rr
    assign rr_victim_way = '0;
  end

  end  // gen_l2

endmodule
