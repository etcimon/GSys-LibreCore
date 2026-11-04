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
  function automatic logic [129:0] extent_bounds(
      input logic [63:0] addr, input logic [7:0] len,
      input logic [2:0] size, input logic [1:0] burst);
    logic [64:0] unit_bytes, span, aligned, first_byte, last_byte;
    unit_bytes = 65'd1 << size;
    span = (65'(len) + 65'd1) << size;
    aligned = {1'b0, addr} & ~(unit_bytes - 65'd1);
    first_byte = {1'b0, addr};
    last_byte = aligned + unit_bytes - 65'd1;
    case (burst)
      2'b01: last_byte = aligned + span - 65'd1;
      2'b10: begin
        first_byte = {1'b0, addr} & ~(span - 65'd1);
        last_byte = first_byte + span - 65'd1;
      end
      default:;
    endcase
    return {last_byte, first_byte};
  endfunction

  function automatic logic request_legal(
      input logic [63:0] addr, input logic [7:0] len,
      input logic [2:0] size, input logic [1:0] burst, input logic lock);
    logic [64:0] unit_bytes, span, first_byte, last_byte;
    unit_bytes = 65'd1 << size;
    span = (65'(len) + 65'd1) << size;
    {last_byte, first_byte} = extent_bounds(addr, len, size, burst);
    if (lock || int'(size) > $clog2(Bytes)) return 1'b0;
    case (burst)
      2'b00: if (len > 8'd15) return 1'b0;
      2'b01:;
      2'b10: if (!(len == 1 || len == 3 || len == 7 || len == 15) ||
          ({1'b0, addr} & (unit_bytes - 65'd1)) != 0) return 1'b0;
      default: return 1'b0;
    endcase
    // MapEn=1 delegates coverage to the sequential walker; the flat window
    // bounds apply only in the unchanged MapEn=0 profile. The AXI encoding,
    // size, lock, WRAP, 4-KiB and 65-bit overflow rules are identical either way.
    return !last_byte[64] && (first_byte >> 12) == (last_byte >> 12) &&
        (MapEn || (first_byte >= {1'b0, BaseAddr} && last_byte < RegionEnd));
  endfunction

  function automatic logic [Bytes-1:0] lanes(
      input logic [63:0] addr, input logic [2:0] size);
    logic [64:0] word_base, last_byte, lane_addr, unit_bytes;
    logic [Bytes-1:0] result;
    result = '0;
    unit_bytes = 65'd1 << size;
    word_base = {1'b0, addr} & ~65'(Bytes - 1);
    last_byte = ({1'b0, addr} & ~(unit_bytes - 65'd1)) + unit_bytes - 65'd1;
    for (int i = 0; i < Bytes; i++) begin
      lane_addr = word_base + 65'(i);
      result[i] = lane_addr >= {1'b0, addr} && lane_addr <= last_byte;
    end
    return result;
  endfunction

  function automatic logic [63:0] next_addr(
      input logic [63:0] addr, input logic [7:0] len,
      input logic [2:0] size, input logic [1:0] burst);
    logic [64:0] unit_bytes, span, incremented;
    unit_bytes = 65'd1 << size;
    span = (65'(len) + 65'd1) << size;
    incremented = ({1'b0, addr} & ~(unit_bytes - 65'd1)) + unit_bytes;
    if (burst == 2'b00) return addr;
    if (burst == 2'b10)
      return 64'(({1'b0, addr} & ~(span - 65'd1)) | (incremented & (span - 65'd1)));
    return 64'(incremented);
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
  typedef struct packed {
    logic w_active, w_done, w_fault, w_buf, w_buf_last, b_valid, b_error;
    logic w_walk;
    logic [IdWidth-1:0] w_id;
    logic [UserWidth-1:0] w_user;
    logic [63:0] w_addr, w_word;
    logic [7:0] w_len, w_left, w_beat, w_source;
    logic [2:0] w_size;
    logic [1:0] w_burst;
    logic [31:0] w_seq, w_generation;
    logic [DataWidth-1:0] w_data;
    logic [Bytes-1:0] w_mask;
    txn_id_t w_tag;
    logic r_active, r_fault, r_valid, r_error;
    logic r_walk;
    logic [IdWidth-1:0] r_id;
    logic [UserWidth-1:0] r_user;
    logic [63:0] r_addr;
    logic [7:0] r_len, r_left, r_beat, r_source;
    logic [2:0] r_size;
    logic [1:0] r_burst;
    logic [31:0] r_seq, r_generation;
    logic [DataWidth-1:0] r_data;
    mem_state_t mem_state;
    logic m_write, m_last, prefer_write;
    logic [7:0] m_slot;
    logic [63:0] m_addr;
    logic [DataWidth-1:0] m_data;
    logic [Bytes-1:0] m_mask;
    txn_id_t m_tag;
    logic [32:0] allocated;
    logic [2:0] faults;
    logic [7:0] w_walk_i, r_walk_i;
    logic [64:0] w_cursor, r_cursor, w_last, r_last;
  } state_t;
  state_t q, d;
  logic want_read, want_write, read_inflight, write_inflight, malformed_w;
  logic aw_ok, ar_ok;
  logic [Bytes-1:0] write_lanes;
  logic [63:0] beat_word;
  logic found;

  assign service_ready_o = rst_ni && ModelLegal;
  assign sequence_exhausted_o = q.allocated == SeqLimit;
  assign faults_o = q.faults;
  assign mem_req_o = service_ready_o && q.mem_state == MGrant;
  assign inflight_o = q.w_active || q.r_active || q.mem_state != MIdle;
  assign mem_we_o = q.m_write;
  assign mem_addr_o = q.m_addr;
  assign mem_wdata_o = q.m_data;
  assign mem_be_o = q.m_mask;
  assign mem_tag_o = q.m_tag;
  assign mem_slot_o = q.m_slot;

  always_comb begin
    d = q;
    resp_o = '0;
    events_o = '0;
    beat_word = '0;
    found = 1'b0;
    read_inflight = q.mem_state != MIdle && !q.m_write;
    write_inflight = q.mem_state != MIdle && q.m_write;
    write_lanes = lanes(q.w_addr, q.w_size);
    malformed_w = req_i.w.last != (q.w_left == 0) ||
        (req_i.w.strb & ~write_lanes) != 0 || req_i.w.user != '0;
    aw_ok = mem_ready_i && request_legal(req_i.aw.addr, req_i.aw.len,
        req_i.aw.size, req_i.aw.burst, req_i.aw.lock);
    ar_ok = mem_ready_i && request_legal(req_i.ar.addr, req_i.ar.len,
        req_i.ar.size, req_i.ar.burst, req_i.ar.lock);
    want_read = q.r_active && !q.r_valid && !q.r_fault && !q.r_walk && mem_ready_i;
    want_write = q.w_buf && !q.w_fault && !q.w_walk && mem_ready_i;
    if (service_ready_o) begin
      resp_o.aw_ready = !q.w_active;
      resp_o.w_ready = q.w_active && !q.w_done && !q.w_buf && !q.w_walk;
      resp_o.ar_ready = !q.r_active;
      resp_o.b_valid = q.b_valid;
      resp_o.b.id = q.w_id;
      resp_o.b.user = q.w_user;
      resp_o.b.resp = q.b_error ? RespSlvErr : 2'b00;
      resp_o.r_valid = q.r_valid;
      resp_o.r.id = q.r_id;
      resp_o.r.user = q.r_user;
      resp_o.r.data = q.r_data;
      resp_o.r.resp = q.r_error ? RespSlvErr : 2'b00;
      resp_o.r.last = q.r_left == 0;
      events_o.aw_accept = req_i.aw_valid && resp_o.aw_ready;
      events_o.ar_accept = req_i.ar_valid && resp_o.ar_ready;
      events_o.w_accept = req_i.w_valid && resp_o.w_ready;
      events_o.b_retire = q.b_valid && req_i.b_ready;
      events_o.r_retire = q.r_valid && req_i.r_ready;
      events_o.b_error = events_o.b_retire && q.b_error;
      events_o.r_error = events_o.r_retire && q.r_error;

      // Reserve the entire sequence range before any side effect, AW first.
      if (events_o.aw_accept) begin
        d.w_active = 1'b1;
        d.w_done = 1'b0;
        d.w_id = req_i.aw.id;
        d.w_user = req_i.aw.user;
        d.w_addr = req_i.aw.addr;
        d.w_len = req_i.aw.len;
        d.w_left = req_i.aw.len;
        d.w_beat = 0;
        d.w_size = req_i.aw.size;
        d.w_burst = req_i.aw.burst;
        d.w_source = source_i;
        d.w_generation = reset_generation_i;
        d.w_fault = 1'b1;
        if (aw_ok && d.allocated + 33'(req_i.aw.len) + 33'd1 <= SeqLimit) begin
          d.w_fault = 1'b0;
          d.w_seq = 32'(d.allocated);
          d.allocated = d.allocated + 33'(req_i.aw.len) + 33'd1;
          if (MapEn) begin
            d.w_walk = 1'b1;
            d.w_walk_i = '0;
            {d.w_last, d.w_cursor} = extent_bounds(req_i.aw.addr, req_i.aw.len,
                req_i.aw.size, req_i.aw.burst);
          end
        end else begin
          events_o.aw_refuse = 1'b1;
          if (aw_ok) begin
            events_o.seq_refuse[1] = 1'b1;
            d.faults[2] = 1'b1;
          end
        end
      end
      if (events_o.ar_accept) begin
        d.r_active = 1'b1;
        d.r_id = req_i.ar.id;
        d.r_user = req_i.ar.user;
        d.r_addr = req_i.ar.addr;
        d.r_len = req_i.ar.len;
        d.r_left = req_i.ar.len;
        d.r_beat = 0;
        d.r_size = req_i.ar.size;
        d.r_burst = req_i.ar.burst;
        d.r_source = source_i;
        d.r_generation = reset_generation_i;
        d.r_fault = 1'b1;
        if (ar_ok && d.allocated + 33'(req_i.ar.len) + 33'd1 <= SeqLimit) begin
          d.r_fault = 1'b0;
          d.r_seq = 32'(d.allocated);
          d.allocated = d.allocated + 33'(req_i.ar.len) + 33'd1;
          if (MapEn) begin
            d.r_walk = 1'b1;
            d.r_walk_i = '0;
            {d.r_last, d.r_cursor} = extent_bounds(req_i.ar.addr, req_i.ar.len,
                req_i.ar.size, req_i.ar.burst);
          end
        end else begin
          events_o.ar_refuse = 1'b1;
          if (ar_ok) begin
            events_o.seq_refuse[0] = 1'b1;
            d.faults[2] = 1'b1;
          end
        end
      end
      if (events_o.b_retire) begin
        d.b_valid = 1'b0;
        d.w_active = 1'b0;
      end
      if (events_o.r_retire) begin
        d.r_valid = 1'b0;
        if (q.r_left == 0) d.r_active = 1'b0;
        else begin
          d.r_left = q.r_left - 1'b1;
          d.r_beat = q.r_beat + 1'b1;
          d.r_addr = next_addr(q.r_addr, q.r_len, q.r_size, q.r_burst);
        end
      end
      if (events_o.w_accept) begin
        events_o.w_protocol_error = malformed_w;
        if (q.w_left == 0) d.w_done = 1'b1;
        else begin
          d.w_left = q.w_left - 1'b1;
          d.w_beat = q.w_beat + 1'b1;
          d.w_addr = next_addr(q.w_addr, q.w_len, q.w_size, q.w_burst);
        end
        if (q.w_fault || malformed_w || !mem_ready_i) begin
          d.w_fault = 1'b1;
          if (q.w_left == 0) begin
            d.b_valid = 1'b1;
            d.b_error = 1'b1;
          end
        end else if (req_i.w.strb == '0) begin
          if (q.w_left == 0) begin
            d.b_valid = 1'b1;
            d.b_error = 1'b0;
          end
        end else begin
          d.w_buf = 1'b1;
          d.w_buf_last = q.w_left == 0;
          // MapEn keeps the absolute beat word for per-beat slot lookup.
          d.w_word = (q.w_addr & ~64'(Bytes - 1)) - (MapEn ? 64'd0 : BaseAddr);
          d.w_data = req_i.w.data;
          d.w_mask = req_i.w.strb;
          d.w_tag = '{reset_generation: q.w_generation,
              seq: q.w_seq + 32'(q.w_beat), axi_id: 16'(q.w_id),
              source: q.w_source, beat: q.w_beat};
        end
      end
      // Sequential coverage walkers, one per context, each <= Regions cycles.
      // Cursor advances across the captured extent; a gap, missing permission
      // or end of table takes the existing refusal path with zero commands.
      if (q.w_walk) begin
        if (q.w_cursor > q.w_last) d.w_walk = 1'b0;
        else if (q.w_walk_i >= Regions) begin
          d.w_walk = 1'b0; d.w_fault = 1'b1; events_o.aw_refuse = 1'b1;
        end else if (q.w_cursor < {1'b0, active_map[q.w_walk_i].base}) begin
          d.w_walk = 1'b0; d.w_fault = 1'b1; events_o.aw_refuse = 1'b1;
        end else if (q.w_cursor >= {1'b0, active_map[q.w_walk_i].base} +
                     {1'b0, active_map[q.w_walk_i].bytes}) begin
          d.w_walk_i = q.w_walk_i + 1'b1;
        end else if (!active_map[q.w_walk_i].write) begin
          d.w_walk = 1'b0; d.w_fault = 1'b1; events_o.aw_refuse = 1'b1;
        end else begin
          d.w_cursor = {1'b0, active_map[q.w_walk_i].base} +
              {1'b0, active_map[q.w_walk_i].bytes};
          d.w_walk_i = q.w_walk_i + 1'b1;
        end
      end
      if (q.r_walk) begin
        if (q.r_cursor > q.r_last) d.r_walk = 1'b0;
        else if (q.r_walk_i >= Regions) begin
          d.r_walk = 1'b0; d.r_fault = 1'b1; events_o.ar_refuse = 1'b1;
        end else if (q.r_cursor < {1'b0, active_map[q.r_walk_i].base}) begin
          d.r_walk = 1'b0; d.r_fault = 1'b1; events_o.ar_refuse = 1'b1;
        end else if (q.r_cursor >= {1'b0, active_map[q.r_walk_i].base} +
                     {1'b0, active_map[q.r_walk_i].bytes}) begin
          d.r_walk_i = q.r_walk_i + 1'b1;
        end else if (!active_map[q.r_walk_i].read) begin
          d.r_walk = 1'b0; d.r_fault = 1'b1; events_o.ar_refuse = 1'b1;
        end else begin
          d.r_cursor = {1'b0, active_map[q.r_walk_i].base} +
              {1'b0, active_map[q.r_walk_i].bytes};
          d.r_walk_i = q.r_walk_i + 1'b1;
        end
      end
      // Error responses use reserved AXI storage, without a memory command.
      if (q.r_active && !q.r_valid && !read_inflight && !q.r_walk &&
          (q.r_fault || !mem_ready_i)) begin
        d.r_valid = 1'b1;
        d.r_error = 1'b1;
        d.r_data = '0;
        d.r_fault = 1'b1;
      end
      if (q.w_buf && !write_inflight && !q.w_walk && (q.w_fault || !mem_ready_i)) begin
        d.w_buf = 1'b0;
        d.w_fault = 1'b1;
        if (q.w_buf_last) begin
          d.b_valid = 1'b1;
          d.b_error = 1'b1;
        end
      end
      // Once offered, a command is immutable until grant, including its tag.
      beat_word = want_write && (!want_read || q.prefer_write) ?
                  q.w_word : q.r_addr & ~64'(Bytes - 1);
      for (int i = 0; i < Regions && !found; i++)
        if ({1'b0, active_map[i].base} <= {1'b0, beat_word} &&
            {1'b0, beat_word} < {1'b0, active_map[i].base} +
                {1'b0, active_map[i].bytes})
          found = 1'b1;
      if (q.mem_state == MIdle && (want_read || want_write)) begin
        d.mem_state = MGrant;
        for (int i = 0; i < Regions; i++)
          if ({1'b0, active_map[i].base} <= {1'b0, beat_word} &&
              {1'b0, beat_word} < {1'b0, active_map[i].base} +
                  {1'b0, active_map[i].bytes}) begin
            d.m_slot = active_map[i].slot;
            d.m_addr = active_map[i].offset + (beat_word - active_map[i].base);
          end
        if (want_write && (!want_read || q.prefer_write)) begin
          d.m_write = 1'b1;
          d.m_last = q.w_buf_last;
          if (!MapEn) d.m_addr = q.w_word;
          d.m_data = q.w_data;
          d.m_mask = q.w_mask;
          d.m_tag = q.w_tag;
        end else begin
          d.m_write = 1'b0;
          d.m_last = q.r_left == 0;
          if (!MapEn) d.m_addr = (q.r_addr & ~64'(Bytes - 1)) - BaseAddr;
          d.m_data = '0;
          d.m_mask = lanes(q.r_addr, q.r_size);
          d.m_tag = '{reset_generation: q.r_generation,
              seq: q.r_seq + 32'(q.r_beat), axi_id: 16'(q.r_id),
              source: q.r_source, beat: q.r_beat};
        end
        // pragma translate_off
        if (MapEn && !found)
          $fatal(1, "STORAMIC_MAP_LOOKUP_MISS");
        // pragma translate_on
      end
      if (q.mem_state == MGrant && mem_gnt_i) begin
        d.mem_state = MResponse;
        d.prefer_write = !q.m_write;
      end
      if (mem_rvalid_i) begin
        if (q.mem_state == MResponse && mem_tag_i == q.m_tag) begin
          d.mem_state = MIdle;
          events_o.mem_error = mem_error_i || !mem_ready_i;
          if (events_o.mem_error) d.faults[1] = 1'b1;
          else begin
            events_o.mem_read = !q.m_write;
            events_o.mem_write = q.m_write;
            events_o.mem_bytes = 8'($countones(q.m_mask));
          end
          if (q.m_write) begin
            d.w_buf = 1'b0;
            d.w_fault = q.w_fault || events_o.mem_error;
            if (q.m_last) begin
              d.b_valid = 1'b1;
              d.b_error = q.w_fault || events_o.mem_error;
            end
          end else begin
            d.r_valid = 1'b1;
            d.r_error = q.r_fault || events_o.mem_error;
            d.r_fault = q.r_fault || events_o.mem_error;
            d.r_data = d.r_error ? '0 : mask_data(mem_rdata_i, q.m_mask);
          end
        end else begin
          events_o.stale_completion = 1'b1;
          d.faults[0] = 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) q <= '0;
    else q <= d;
  end
endmodule
