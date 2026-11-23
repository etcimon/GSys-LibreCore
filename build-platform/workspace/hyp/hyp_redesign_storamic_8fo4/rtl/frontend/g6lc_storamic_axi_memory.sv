// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// One read and one write context, one external memory command in flight.
// No new clock/CDC: command and response bindings share clk_i/reset semantics.
// Address validation is registered at admission; memory offers are registered.
module g6lc_storamic_axi_memory #(
  parameter int unsigned DataWidth = 64,
  parameter int unsigned SeqWidth = 32,
  parameter logic [63:0] BaseAddr = 64'h8000_0000,
  parameter logic [63:0] RegionBytes = 64'd65536,
  // ST-008B: map/capacity-driven slot routing. MapEn=0 keeps the flat
  // BaseAddr/RegionBytes window and is bit-for-bit unchanged. With MapEn the
  // region lookup on each registered beat address adds a MaxRegions-wide
  // comparator cone before the offer register, and admission walkers add
  // <= Regions cycles of latency; no new clock/reset domain, no arrays.
  parameter bit MapEn = 1'b0,
  parameter int unsigned Slots = 1,
  parameter int unsigned Regions = 1,
  parameter g6lc_storamic_region_pkg::slot_map_t SlotMap = '0,
  parameter g6lc_storamic_region_pkg::region_map_t RegionMap = '0,
  // ST-010B: when BootMapEn=0 the map is a runtime input committed by the
  // control block; the RegionMap/SlotMap parameters are ignored and there is
  // no elaboration legality check on them.
  parameter bit BootMapEn = 1'b1,
  parameter type req_t = g6lc_storamic_pkg::axi_req_t,
  parameter type resp_t = g6lc_storamic_pkg::axi_resp_t
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  // Seal new address admission only; accepted W/B/R work must still drain.
  input logic quiesce_i,
  output logic quiesced_o,
  input req_t req_i,
  output resp_t resp_o,
  input logic [7:0] source_i,
  input logic [31:0] reset_generation_i,
  output logic service_ready_o,
  output logic sequence_exhausted_o,
  output logic [2:0] faults_o,
  output g6lc_storamic_pkg::model_events_t events_o,
  output logic inflight_o,
  input logic mem_ready_i,
  output logic mem_req_o,
  input logic mem_gnt_i,
  output logic mem_we_o,
  output logic [63:0] mem_addr_o,
  output logic [DataWidth-1:0] mem_wdata_o,
  output logic [(DataWidth >= 8 ? DataWidth/8 : 1)-1:0] mem_be_o,
  output g6lc_storamic_pkg::txn_id_t mem_tag_o,
  output logic [7:0] mem_slot_o,
  input logic mem_rvalid_i,
  input logic [DataWidth-1:0] mem_rdata_i,
  input logic mem_error_i,
  input g6lc_storamic_pkg::txn_id_t mem_tag_i,
  // ST-010B runtime committed map (used only when MapEn && !BootMapEn).
  input logic map_valid_i,
  input g6lc_storamic_region_pkg::slot_map_t slot_map_i,
  input g6lc_storamic_region_pkg::region_map_t region_map_i
);
  import g6lc_storamic_pkg::*;
  localparam int unsigned Bytes = DataWidth >= 8 ? DataWidth / 8 : 1;
  localparam int unsigned IdWidth = $bits(req_i.aw.id);
  localparam int unsigned UserWidth = $bits(req_i.aw.user);
  localparam logic [64:0] RegionEnd = {1'b0, BaseAddr} + {1'b0, RegionBytes};
  localparam logic [32:0] SeqLimit = 33'd1 << SeqWidth;
  localparam bit Legal = DataWidth >= 8 && DataWidth <= 1024 &&
      (DataWidth & (DataWidth - 1)) == 0 && SeqWidth >= 1 && SeqWidth <= 32 &&
      IdWidth >= 1 && IdWidth <= 16 && UserWidth >= 1 &&
      $bits(req_i.ar.id) == IdWidth && $bits(resp_o.b.id) == IdWidth &&
      $bits(resp_o.r.id) == IdWidth && $bits(req_i.aw.addr) == 64 &&
      $bits(req_i.ar.addr) == 64 && $bits(req_i.w.data) == DataWidth &&
      $bits(req_i.w.strb) == Bytes && $bits(resp_o.r.data) == DataWidth &&
      $bits(req_i.ar.user) == UserWidth && $bits(resp_o.b.user) == UserWidth &&
      $bits(resp_o.r.user) == UserWidth && RegionBytes != 0 &&
      (BaseAddr & 64'(Bytes - 1)) == 0 && (RegionBytes & 64'(Bytes - 1)) == 0 &&
      RegionEnd <= 65'h1_0000_0000_0000_0000;
  localparam bit MapLegal = !MapEn || !BootMapEn || (
      Slots >= 1 && Slots <= g6lc_storamic_cfg_pkg::MaxSupportedSticks &&
      Regions >= 1 && Regions <= g6lc_storamic_region_pkg::MaxRegions &&
      g6lc_storamic_region_pkg::map_check(
          SlotMap, Slots, RegionMap, Regions, Bytes) ==
      g6lc_storamic_region_pkg::MapOk);
  // Active map: elaboration parameter in boot mode, committed runtime input
  // otherwise. Stable while map_valid_i (guaranteed by the commit protocol).
  // Before commit the runtime map is empty, so every data request is accepted
  // and refused by the extent walker without issuing a slot command.
  localparam bit RuntimeMap = MapEn && !BootMapEn;
  g6lc_storamic_region_pkg::region_map_t active_map;
  assign active_map = BootMapEn ? RegionMap : (map_valid_i ? region_map_i : '0);
  localparam bit ModelLegal = Legal && MapLegal;

  // pragma translate_off
  initial begin
    if (!ModelLegal) $fatal(1, "STORAMIC_MODEL_CONFIG_ILLEGAL");
  end
  g6lc_storamic_region_pkg::region_map_t prev_rmap;
  g6lc_storamic_region_pkg::slot_map_t prev_smap;
  logic prev_map_valid = 1'b0;
  always @(posedge clk_i) begin
    // The map publishes together with map_valid_i; it is frozen afterwards.
    if (rst_ni && RuntimeMap && map_valid_i && prev_map_valid) begin
      assert (region_map_i == prev_rmap)
        else $fatal(1, "STORAMIC_RTMAP_CHANGED");
      assert (slot_map_i == prev_smap)
        else $fatal(1, "STORAMIC_RTMAP_CHANGED");
    end
    prev_rmap <= region_map_i;
    prev_smap <= slot_map_i;
    prev_map_valid <= rst_ni && map_valid_i;
  end
  // pragma translate_on

  // Full addressed extent [first_byte, last_byte] for any burst shape:
  // FIXED repeats its aligned unit, INCR spans the whole burst and WRAP
  // covers the entire wrap window. {last_byte, first_byte}, both 65-bit.
  // Narrow 12-bit within-page next_addr (legal AXI4 bursts never cross 4 KiB).
  function automatic logic [63:0] next_addr(
      input logic [63:0] addr, input logic [7:0] len,
      input logic [2:0] size, input logic [1:0] burst);
    logic [11:0] unit_bytes, span_m1, inc12, next12;
    unit_bytes = 12'd1 << size;
    span_m1    = ((12'(len) + 12'd1) << size) - 12'd1;
    inc12      = (addr[11:0] & ~(unit_bytes - 12'd1)) + unit_bytes;
    if (burst == 2'b00) next12 = addr[11:0];
    else if (burst == 2'b10) next12 = (addr[11:0] & ~span_m1) | (inc12 & span_m1);
    else next12 = inc12;
    return {addr[63:12], next12};
  endfunction

  function automatic logic [DataWidth-1:0] mask_data(
      input logic [DataWidth-1:0] data, input logic [Bytes-1:0] mask);
    logic [DataWidth-1:0] result;
    result = '0;
    for (int i = 0; i < Bytes; i++)
      result[8*i +: 8] = mask[i] ? data[8*i +: 8] : 8'b0;
    return result;
  endfunction

  typedef enum logic [1:0] {MIdle, MGrant, MResponse} mem_state_t;

  // A38 functional decomposition into four disjoint state structs (AW/W/B,
  // AR/R, MemArb, Seq/Faults) with independent always_comb/always_ff processes
  // so no channel's writes serialize another channel's bundle makespan.
  typedef struct packed {
    logic active, done, fault, buf_v, buf_last, b_valid, b_error, walk;
    logic [IdWidth-1:0]   id;
    logic [UserWidth-1:0] user;
    logic [63:0]          addr, word;
    logic [7:0]           len, left, beat, source;
    logic [2:0]           size;
    logic [1:0]           burst;
    logic [31:0]          seq, generation;
    logic [DataWidth-1:0] data;
    logic [Bytes-1:0]     mask;
    txn_id_t              tag;
    logic [7:0]           walk_i;
    logic [64:0]          cursor, last;
  } w_state_t;

  typedef struct packed {
    logic active, fault, valid, error, walk;
    logic [IdWidth-1:0]   id;
    logic [UserWidth-1:0] user;
    logic [63:0]          addr;
    logic [7:0]           len, left, beat, source;
    logic [2:0]           size;
    logic [1:0]           burst;
    logic [31:0]          seq, generation;
    logic [DataWidth-1:0] data;
    logic [7:0]           walk_i;
    logic [64:0]          cursor, last;
  } r_state_t;

  typedef struct packed {
    mem_state_t           mem_state;
    logic                 m_write, m_last, prefer_write;
    logic [7:0]           m_slot;
    logic [63:0]          m_addr;
    logic [DataWidth-1:0] m_data;
    logic [Bytes-1:0]     m_mask;
    txn_id_t              m_tag;
  } m_state_t;

  typedef struct packed {
    logic [32:0] allocated;
    logic [7:0]  epoch;
    logic [2:0]  faults;
  } s_state_t;

  w_state_t wq, wd;
  r_state_t rq, rd;
  m_state_t mq, md;
  s_state_t sq, sd;

  logic want_read, want_write, read_inflight, write_inflight, malformed_w;
  logic aw_legal, ar_legal, aw_ok, ar_ok;
  logic [64:0] aw_first_b, aw_last_b, ar_first_b, ar_last_b;
  logic [Bytes-1:0] write_lanes, read_lanes;
  logic [63:0] beat_word;
  logic found;
  localparam int unsigned OffW = (Bytes > 1) ? $clog2(Bytes) : 1;

  // Extracted narrow-width decode submodules (replaces 144-FO4 65-bit lanes()
  // and 65-bit extent/legality functions).
  g6lc_storamic_axi_lanes #(.Bytes(Bytes)) i_w_lanes (
    .off_i(wq.addr[OffW-1:0]), .size_i(wq.size), .lanes_o(write_lanes)
  );
  g6lc_storamic_axi_lanes #(.Bytes(Bytes)) i_r_lanes (
    .off_i(rq.addr[OffW-1:0]), .size_i(rq.size), .lanes_o(read_lanes)
  );
  g6lc_storamic_axi_req_check #(
    .Bytes(Bytes), .MapEn(MapEn), .BaseAddr(BaseAddr), .RegionBytes(RegionBytes)
  ) i_aw_chk (
    .addr_i(req_i.aw.addr), .len_i(req_i.aw.len), .size_i(req_i.aw.size),
    .burst_i(req_i.aw.burst), .lock_i(req_i.aw.lock),
    .legal_o(aw_legal), .first_byte_o(aw_first_b), .last_byte_o(aw_last_b)
  );
  g6lc_storamic_axi_req_check #(
    .Bytes(Bytes), .MapEn(MapEn), .BaseAddr(BaseAddr), .RegionBytes(RegionBytes)
  ) i_ar_chk (
    .addr_i(req_i.ar.addr), .len_i(req_i.ar.len), .size_i(req_i.ar.size),
    .burst_i(req_i.ar.burst), .lock_i(req_i.ar.lock),
    .legal_o(ar_legal), .first_byte_o(ar_first_b), .last_byte_o(ar_last_b)
  );

  assign service_ready_o      = rst_ni && ModelLegal;
  assign sequence_exhausted_o = sq.allocated == SeqLimit;
  assign faults_o             = sq.faults;
  assign mem_req_o            = service_ready_o && (mq.mem_state == MGrant);
  assign inflight_o           = wq.active || rq.active || (mq.mem_state != MIdle);
  assign quiesced_o           = rst_ni && quiesce_i && !inflight_o;
  assign mem_we_o             = mq.m_write;
  assign mem_addr_o           = mq.m_addr;
  assign mem_wdata_o          = mq.m_data;
  assign mem_be_o             = mq.m_mask;
  assign mem_tag_o            = mq.m_tag;
  assign mem_slot_o           = mq.m_slot;

  // A105/A118 parallel sequence allocator + A146 byte-sliced 33-bit muxes.
  logic        seq_renew_ev, aw_ready_w, w_ready_w, ar_ready_w;
  logic        aw_acc_w, ar_acc_w, w_acc_w, b_ret_w, r_ret_w;
  logic [32:0] alloc_base, aw_span33, ar_span33, aw_end_a, ar_end_only, ar_end_both;
  logic        aw_fits, ar_fits_after_aw, ar_fits_only, aw_admit, ar_admit;
  logic [32:0] alloc_next;
  logic [7:0]  epoch_next;
  logic [31:0] aw_seq_assigned, ar_seq_assigned;

  assign seq_renew_ev = service_ready_o && (sq.allocated == SeqLimit) && !inflight_o && (sq.epoch != '1);
  for (genvar b = 0; b < 33; b = b + 8) begin : gen_alloc_base_lane
    localparam int unsigned LW = ((b + 8) <= 33) ? 8 : (33 - b);
    logic ren_b;
    assign ren_b = service_ready_o && (sq.allocated == SeqLimit) && !inflight_o && (sq.epoch != '1);
    assign alloc_base[b +: LW] = ren_b ? '0 : sq.allocated[b +: LW];
  end
  assign epoch_next   = seq_renew_ev ? (sq.epoch + 8'd1) : sq.epoch;
  assign aw_ready_w   = service_ready_o && !wq.active && !quiesce_i;
  assign w_ready_w    = service_ready_o && wq.active && !wq.done && !wq.buf_v && !wq.walk;
  assign ar_ready_w   = service_ready_o && !rq.active && !quiesce_i;
  assign aw_acc_w     = req_i.aw_valid && aw_ready_w;
  assign ar_acc_w     = req_i.ar_valid && ar_ready_w;
  assign w_acc_w      = req_i.w_valid  && w_ready_w;
  assign b_ret_w      = service_ready_o && wq.b_valid && req_i.b_ready;
  assign r_ret_w      = service_ready_o && rq.valid   && req_i.r_ready;

  assign aw_ok       = mem_ready_i && aw_legal;
  assign ar_ok       = mem_ready_i && ar_legal;
  assign aw_span33   = 33'(req_i.aw.len) + 33'd1;
  assign ar_span33   = 33'(req_i.ar.len) + 33'd1;
  assign aw_end_a    = alloc_base + aw_span33;
  assign ar_end_only = alloc_base + ar_span33;
  assign ar_end_both = alloc_base + (aw_span33 + ar_span33);
  assign aw_fits          = (aw_end_a    <= SeqLimit);
  assign ar_fits_only     = (ar_end_only <= SeqLimit);
  assign ar_fits_after_aw = (ar_end_both <= SeqLimit);
  assign aw_admit         = aw_acc_w && aw_ok && aw_fits;
  assign ar_admit         = ar_acc_w && ar_ok && (aw_admit ? ar_fits_after_aw : ar_fits_only);
  assign aw_seq_assigned  = 32'(alloc_base);
  for (genvar b = 0; b < 32; b = b + 8) begin : gen_arseq_lane
    logic aw_a_b;
    assign aw_a_b = aw_admit;
    assign ar_seq_assigned[b +: 8] = aw_a_b ? aw_end_a[b +: 8] : alloc_base[b +: 8];
  end
  for (genvar b = 0; b < 33; b = b + 8) begin : gen_alloc_next_lane
    localparam int unsigned LW = ((b + 8) <= 33) ? 8 : (33 - b);
    logic s_both, s_aw, s_ar;
    assign s_both = aw_admit && ar_admit;
    assign s_aw   = aw_admit && !ar_admit;
    assign s_ar   = !aw_admit && ar_admit;
    assign alloc_next[b +: LW] = s_both ? ar_end_both[b +: LW] :
                                 s_aw   ? aw_end_a[b +: LW] :
                                 s_ar   ? ar_end_only[b +: LW] :
                                          alloc_base[b +: LW];
  end

  // A136 registered per-region derived constants (reg_end_q = base + bytes,
  // reg_delta_q = offset - base). active_map only changes on map commit, at
  // least 1 cycle before any AW/AR completes its walk and reaches MIdle;
  // removes the 12.0-FO4 64-bit subtractor ahead of the address adder.
  logic [64:0] reg_end_q   [Regions];
  logic [63:0] reg_delta_q [Regions];
  for (genvar ri = 0; ri < Regions; ri++) begin : gen_reg_cache
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        reg_end_q[ri]   <= {1'b0, RegionMap[ri].base} + {1'b0, RegionMap[ri].bytes};
        reg_delta_q[ri] <= RegionMap[ri].offset - RegionMap[ri].base;
      end else begin
        reg_end_q[ri]   <= {1'b0, active_map[ri].base} + {1'b0, active_map[ri].bytes};
        reg_delta_q[ri] <= active_map[ri].offset - active_map[ri].base;
      end
    end
  end

  // A122 PushSelect + A105/A146: parallel W and R region lookup directly off flops.
  logic        pick_wr_beat;
  logic [63:0] r_word_aligned, beat_word_c;
  logic [Regions-1:0] w_reg_hit, r_reg_hit;
  logic [63:0] w_reg_cand [Regions], r_reg_cand [Regions];
  logic [7:0]  w_reg_slot, r_reg_slot, reg_hit_slot;
  logic [63:0] w_reg_addr, r_reg_addr, reg_hit_addr;
  assign want_read      = rq.active && !rq.valid && !rq.fault && !rq.walk && mem_ready_i;
  assign want_write     = wq.buf_v  && !wq.fault && !wq.walk  && mem_ready_i;
  assign pick_wr_beat   = want_write && (!want_read || mq.prefer_write);
  assign r_word_aligned = rq.addr & ~64'(Bytes - 1);
  for (genvar ri = 0; ri < Regions; ri++) begin : gen_reg_lk
    assign w_reg_cand[ri] = wq.word + reg_delta_q[ri];
    assign r_reg_cand[ri] = r_word_aligned + reg_delta_q[ri];
    assign w_reg_hit[ri]  = ({1'b0, active_map[ri].base} <= {1'b0, wq.word}) &&
                            ({1'b0, wq.word} < reg_end_q[ri]);
    assign r_reg_hit[ri]  = ({1'b0, active_map[ri].base} <= {1'b0, r_word_aligned}) &&
                            ({1'b0, r_word_aligned} < reg_end_q[ri]);
  end
  always_comb begin : p_reg_pick
    w_reg_slot = '0; w_reg_addr = '0;
    r_reg_slot = '0; r_reg_addr = '0;
    for (int i = 0; i < Regions; i++) begin
      if (w_reg_hit[i]) begin
        w_reg_slot = active_map[i].slot;
        w_reg_addr = w_reg_cand[i];
      end
      if (r_reg_hit[i]) begin
        r_reg_slot = active_map[i].slot;
        r_reg_addr = r_reg_cand[i];
      end
    end
  end
  assign reg_hit_slot = pick_wr_beat ? w_reg_slot : r_reg_slot;
  for (genvar b = 0; b < 8; b++) begin : gen_rha_lane
    logic pwb_b;
    assign pwb_b = pick_wr_beat;
    assign reg_hit_addr[b*8 +: 8] = pwb_b ? w_reg_addr[b*8 +: 8] : r_reg_addr[b*8 +: 8];
    assign beat_word_c[b*8 +: 8]  = pwb_b ? wq.word[b*8 +: 8]    : r_word_aligned[b*8 +: 8];
  end

  assign read_inflight  = (mq.mem_state != MIdle) && !mq.m_write;
  assign write_inflight = (mq.mem_state != MIdle) &&  mq.m_write;
  assign malformed_w    = (req_i.w.last != (wq.left == 0)) || ((req_i.w.strb & ~write_lanes) != 0);
  assign beat_word      = beat_word_c;
  assign found          = pick_wr_beat ? (|w_reg_hit) : (|r_reg_hit);

  // Shared memory-completion & walker-end precomputes (hoisted once).
  logic mem_rsp_match, mem_rsp_stale, mem_rsp_err;
  assign mem_rsp_match = service_ready_o && mem_rvalid_i &&
                         (mq.mem_state == MResponse) && (mem_tag_i == mq.m_tag);
  assign mem_rsp_stale = service_ready_o && mem_rvalid_i && !mem_rsp_match;
  assign mem_rsp_err   = mem_error_i || !mem_ready_i;

  logic [64:0] w_walk_end, r_walk_end;
  assign w_walk_end = {1'b0, active_map[wq.walk_i].base} + {1'b0, active_map[wq.walk_i].bytes};
  assign r_walk_end = {1'b0, active_map[rq.walk_i].base} + {1'b0, active_map[rq.walk_i].bytes};

  logic [63:0] w_next_addr_c, r_next_addr_c;
  assign w_next_addr_c = next_addr(wq.addr, wq.len, wq.size, wq.burst);
  assign r_next_addr_c = next_addr(rq.addr, rq.len, rq.size, rq.burst);

  // Separate output-family continuous assigns for resp_o.
  always_comb begin : p_resp_out
    resp_o          = '0;
    resp_o.aw_ready = aw_ready_w;
    resp_o.w_ready  = w_ready_w;
    resp_o.ar_ready = ar_ready_w;
    resp_o.b_valid  = service_ready_o && wq.b_valid;
    resp_o.b.id     = wq.id;
    resp_o.b.user   = wq.user;
    resp_o.b.resp   = wq.b_error ? RespSlvErr : 2'b00;
    resp_o.r_valid  = service_ready_o && rq.valid;
    resp_o.r.id     = rq.id;
    resp_o.r.user   = rq.user;
    resp_o.r.data   = rq.data;
    resp_o.r.resp   = rq.error ? RespSlvErr : 2'b00;
    resp_o.r.last   = rq.left == 0;
  end

  // ---- Channel 1: Write (AW / W / B + W-walker) ----
  logic aw_refuse_w, w_proto_err_w;
  always_comb begin : p_write_chan
    wd            = wq;
    aw_refuse_w   = 1'b0;
    w_proto_err_w = 1'b0;
    if (service_ready_o) begin
      if (aw_acc_w) begin
        wd.active     = 1'b1;
        wd.done       = 1'b0;
        wd.id         = req_i.aw.id;
        wd.user       = req_i.aw.user;
        wd.addr       = req_i.aw.addr;
        wd.len        = req_i.aw.len;
        wd.left       = req_i.aw.len;
        wd.beat       = '0;
        wd.size       = req_i.aw.size;
        wd.burst      = req_i.aw.burst;
        wd.source     = source_i;
        wd.generation = reset_generation_i;
        wd.fault      = !aw_admit;
        if (aw_admit) begin
          wd.seq = aw_seq_assigned;
          if (MapEn) begin
            wd.walk   = 1'b1;
            wd.walk_i = '0;
            wd.last   = aw_last_b;
            wd.cursor = aw_first_b;
          end
        end else begin
          aw_refuse_w = 1'b1;
          // pragma translate_off
          $display("[sto-awref] t=%0t aw_ok=%b legal=%b a=%h id=%h lock=%h len=%h size=%h burst=%h user=%h", $time,
                   aw_ok, aw_legal,
                   req_i.aw.addr, req_i.aw.id, req_i.aw.lock,
                   req_i.aw.len, req_i.aw.size, req_i.aw.burst, req_i.aw.user);
          // pragma translate_on
        end
      end
      if (b_ret_w) begin
        wd.b_valid = 1'b0;
        wd.active  = 1'b0;
      end
      if (w_acc_w) begin
        w_proto_err_w = malformed_w;
        if (wq.left == 0) wd.done = 1'b1;
        else begin
          wd.left = wq.left - 1'b1;
          wd.beat = wq.beat + 1'b1;
          wd.addr = w_next_addr_c;
        end
        if (wq.fault || malformed_w || !mem_ready_i) begin
          wd.fault = 1'b1;
          if (wq.left == 0) begin
            wd.b_valid = 1'b1;
            wd.b_error = 1'b1;
          end
          // pragma translate_off
          $display("[sto-werr] t=%0t w_fault=%b mal=%b last=%b w_left=%0d strb=%h lanes=%h wuser=%h waddr=%h wsize=%h wid=%h", $time,
                   wq.fault, malformed_w, req_i.w.last, wq.left, req_i.w.strb, write_lanes,
                   req_i.w.user, wq.addr, wq.size, wq.id);
          // pragma translate_on
        end else if (req_i.w.strb == '0) begin
          if (wq.left == 0) begin
            wd.b_valid = 1'b1;
            wd.b_error = 1'b0;
          end
        end else begin
          wd.buf_v    = 1'b1;
          wd.buf_last = (wq.left == 0);
          wd.word     = (wq.addr & ~64'(Bytes - 1)) - (MapEn ? 64'd0 : BaseAddr);
          wd.data     = req_i.w.data;
          wd.mask     = req_i.w.strb;
          wd.tag      = '{reset_generation: wq.generation, epoch: sq.epoch,
                          seq: wq.seq + 32'(wq.beat), axi_id: 16'(wq.id),
                          source: wq.source, beat: wq.beat};
        end
      end
      if (wq.walk) begin
        if (wq.cursor > wq.last) wd.walk = 1'b0;
        else if (wq.walk_i >= Regions || wq.cursor < {1'b0, active_map[wq.walk_i].base}) begin
          wd.walk = 1'b0; wd.fault = 1'b1; aw_refuse_w = 1'b1;
        end else if (wq.cursor >= w_walk_end) begin
          wd.walk_i = wq.walk_i + 1'b1;
        end else if (!active_map[wq.walk_i].write) begin
          wd.walk = 1'b0; wd.fault = 1'b1; aw_refuse_w = 1'b1;
        end else begin
          wd.cursor = w_walk_end;
          wd.walk_i = wq.walk_i + 1'b1;
        end
      end
      if (wq.buf_v && !write_inflight && !wq.walk && (wq.fault || !mem_ready_i)) begin
        wd.buf_v = 1'b0;
        wd.fault = 1'b1;
        if (wq.buf_last) begin
          wd.b_valid = 1'b1;
          wd.b_error = 1'b1;
        end
      end
      if (mem_rsp_match && mq.m_write) begin
        wd.buf_v = 1'b0;
        wd.fault = wq.fault || mem_rsp_err;
        if (mq.m_last) begin
          wd.b_valid = 1'b1;
          wd.b_error = wq.fault || mem_rsp_err;
        end
      end
    end
  end

  // ---- Channel 2: Read (AR / R + R-walker) ----
  logic ar_refuse_w;
  always_comb begin : p_read_chan
    rd          = rq;
    ar_refuse_w = 1'b0;
    if (service_ready_o) begin
      if (ar_acc_w) begin
        rd.active     = 1'b1;
        rd.id         = req_i.ar.id;
        rd.user       = req_i.ar.user;
        rd.addr       = req_i.ar.addr;
        rd.len        = req_i.ar.len;
        rd.left       = req_i.ar.len;
        rd.beat       = '0;
        rd.size       = req_i.ar.size;
        rd.burst      = req_i.ar.burst;
        rd.source     = source_i;
        rd.generation = reset_generation_i;
        rd.fault      = !ar_admit;
        if (ar_admit) begin
          rd.seq = ar_seq_assigned;
          if (MapEn) begin
            rd.walk   = 1'b1;
            rd.walk_i = '0;
            rd.last   = ar_last_b;
            rd.cursor = ar_first_b;
          end
        end else begin
          ar_refuse_w = 1'b1;
        end
      end
      if (r_ret_w) begin
        rd.valid = 1'b0;
        if (rq.left == 0) rd.active = 1'b0;
        else begin
          rd.left = rq.left - 1'b1;
          rd.beat = rq.beat + 1'b1;
          rd.addr = r_next_addr_c;
        end
      end
      if (rq.walk) begin
        if (rq.cursor > rq.last) rd.walk = 1'b0;
        else if (rq.walk_i >= Regions || rq.cursor < {1'b0, active_map[rq.walk_i].base}) begin
          rd.walk = 1'b0; rd.fault = 1'b1; ar_refuse_w = 1'b1;
        end else if (rq.cursor >= r_walk_end) begin
          rd.walk_i = rq.walk_i + 1'b1;
        end else if (!active_map[rq.walk_i].read) begin
          rd.walk = 1'b0; rd.fault = 1'b1; ar_refuse_w = 1'b1;
        end else begin
          rd.cursor = r_walk_end;
          rd.walk_i = rq.walk_i + 1'b1;
        end
      end
      if (rq.active && !rq.valid && !read_inflight && !rq.walk && (rq.fault || !mem_ready_i)) begin
        rd.valid = 1'b1;
        rd.error = 1'b1;
        rd.data  = '0;
        rd.fault = 1'b1;
      end
      if (mem_rsp_match && !mq.m_write) begin
        rd.valid = 1'b1;
        rd.error = rq.fault || mem_rsp_err;
        rd.fault = rq.fault || mem_rsp_err;
        rd.data  = (rq.fault || mem_rsp_err) ? '0 : mask_data(mem_rdata_i, mq.m_mask);
      end
    end
  end

  // ---- Channel 3: Memory Command Arbiter ----
  logic [63:0] r_flat_addr_c;
  assign r_flat_addr_c = r_word_aligned - BaseAddr;
  always_comb begin : p_mem_chan
    md = mq;
    if (service_ready_o) begin
      if ((mq.mem_state == MIdle) && (want_read || want_write)) begin
        md.mem_state = MGrant;
        if (MapEn) begin
          md.m_slot = reg_hit_slot;
          md.m_addr = reg_hit_addr;
        end
        if (pick_wr_beat) begin
          md.m_write = 1'b1;
          md.m_last  = wq.buf_last;
          if (!MapEn) md.m_addr = wq.word;
          md.m_data  = wq.data;
          md.m_mask  = wq.mask;
          md.m_tag   = wq.tag;
        end else begin
          md.m_write = 1'b0;
          md.m_last  = (rq.left == 0);
          if (!MapEn) md.m_addr = r_flat_addr_c;
          md.m_data  = '0;
          md.m_mask  = read_lanes;
          md.m_tag   = '{reset_generation: rq.generation, epoch: sq.epoch,
                         seq: rq.seq + 32'(rq.beat), axi_id: 16'(rq.id),
                         source: rq.source, beat: rq.beat};
        end
        // pragma translate_off
        if (MapEn && !found)
          $fatal(1, "STORAMIC_MAP_LOOKUP_MISS");
        // pragma translate_on
      end
      if ((mq.mem_state == MGrant) && mem_gnt_i) begin
        md.mem_state    = MResponse;
        md.prefer_write = !mq.m_write;
      end
      if (mem_rsp_match) begin
        md.mem_state = MIdle;
      end
    end
  end

  // ---- Channel 4: Sequence / Epoch / Faults + Events ----
  logic aw_seq_ref_w, ar_seq_ref_w;
  assign aw_seq_ref_w = aw_acc_w && !aw_admit && aw_ok;
  assign ar_seq_ref_w = ar_acc_w && !ar_admit && ar_ok;
  always_comb begin : p_seq_fault
    sd = sq;
    if (service_ready_o) begin
      sd.allocated = alloc_next;
      sd.epoch     = epoch_next;
      if (aw_seq_ref_w || ar_seq_ref_w) sd.faults[2] = 1'b1;
      if (mem_rsp_match && mem_rsp_err) sd.faults[1] = 1'b1;
      if (mem_rsp_stale)                sd.faults[0] = 1'b1;
    end
  end

  always_comb begin : p_events_out
    events_o                  = '0;
    events_o.seq_renew        = seq_renew_ev;
    events_o.aw_accept        = aw_acc_w;
    events_o.ar_accept        = ar_acc_w;
    events_o.w_accept         = w_acc_w;
    events_o.b_retire         = b_ret_w;
    events_o.r_retire         = r_ret_w;
    events_o.b_error          = b_ret_w && wq.b_error;
    events_o.r_error          = r_ret_w && rq.error;
    events_o.aw_refuse        = aw_refuse_w;
    events_o.ar_refuse        = ar_refuse_w;
    events_o.seq_refuse[1]    = aw_seq_ref_w;
    events_o.seq_refuse[0]    = ar_seq_ref_w;
    events_o.w_protocol_error = w_proto_err_w;
    events_o.mem_error        = mem_rsp_match && mem_rsp_err;
    events_o.mem_read         = mem_rsp_match && !mem_rsp_err && !mq.m_write;
    events_o.mem_write        = mem_rsp_match && !mem_rsp_err &&  mq.m_write;
    events_o.mem_bytes        = (mem_rsp_match && !mem_rsp_err) ? 8'($countones(mq.m_mask)) : 8'd0;
    events_o.stale_completion = mem_rsp_stale;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wq <= '0;
      rq <= '0;
      mq <= '0;
      sq <= '0;
    end else begin
      wq <= wd;
      rq <= rd;
      mq <= md;
      sq <= sd;
    end
  end
endmodule
