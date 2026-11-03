// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Bounded safety only: no eventual-grant/completion or CPU ownership claim.
module formal_g6lc_storamic_model (
  input logic clk_i,
  input logic rst_ni,
  input g6lc_storamic_pkg::axi_req_t req_i,
  input logic mem_ready_i,
  input logic mem_gnt_i,
  input logic mem_rvalid_i,
  input logic [63:0] mem_rdata_i,
  input logic mem_error_i,
  input g6lc_storamic_pkg::txn_id_t mem_tag_i,
  output logic cover_rw_o,
  output logic cover_stale_o
);
  import g6lc_storamic_pkg::*;
  axi_resp_t resp, previous_resp;
  axi_req_t previous_req;
  logic mem_req, mem_we;
  logic [63:0] mem_addr, mem_wdata;
  logic [7:0] mem_be;
  txn_id_t mem_tag;
  logic past_valid, previous_offer, previous_grant;
  logic [63:0] previous_addr, previous_data;
  logic [7:0] previous_be;
  logic previous_we, previous_stale_read, previous_stale_write;
  txn_id_t previous_tag;
  logic w_pending, w_bad_start, r_bad_start;
  logic [8:0] w_left, w_total, r_left, r_total;
  logic [7:0] w_id, r_id;
  logic w_user, r_user;
  logic memory_live, memory_write;
  txn_id_t live_tag;
  logic [15:0] seen_sequences;
  logic seen_read_command, seen_write_command;
  logic seen_read_response, seen_write_response;
  logic stale_waiting, seen_stale_recovery;
  logic w_had_command, r_had_command;

  // Reachability goals are checked separately from safety assertions. They
  // prevent an idle/error-only execution from standing in for exercised paths.
  assign cover_rw_o = seen_read_command && seen_write_command &&
                      seen_read_response && seen_write_response;
  assign cover_stale_o = seen_stale_recovery;

  g6lc_storamic_axi_memory #(.RegionBytes(256), .SeqWidth(4)) dut (
    .clk_i, .rst_ni, .testmode_i(1'b0), .req_i, .resp_o(resp),
    .source_i(8'h3a), .reset_generation_i(32'b0),
    .service_ready_o(), .sequence_exhausted_o(), .faults_o(), .events_o(),
    .mem_ready_i, .mem_req_o(mem_req), .mem_gnt_i,
    .mem_we_o(mem_we), .mem_addr_o(mem_addr), .mem_wdata_o(mem_wdata),
    .mem_be_o(mem_be), .mem_tag_o(mem_tag),
    .mem_rvalid_i, .mem_rdata_i, .mem_error_i, .mem_tag_i
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      past_valid <= 0;
      previous_resp <= '0;
      previous_req <= '0;
      previous_offer <= 0;
      previous_grant <= 0;
      previous_addr <= 0;
      previous_data <= 0;
      previous_be <= 0;
      previous_we <= 0;
      previous_tag <= '0;
      previous_stale_read <= 0;
      previous_stale_write <= 0;
      w_pending <= 0;
      w_bad_start <= 0;
      r_bad_start <= 0;
      w_left <= 0;
      w_total <= 0;
      r_left <= 0;
      r_total <= 0;
      w_id <= 0;
      r_id <= 0;
      w_user <= 0;
      r_user <= 0;
      memory_live <= 0;
      memory_write <= 0;
      live_tag <= '0;
      seen_sequences <= '0;
      seen_read_command <= 0;
      seen_write_command <= 0;
      seen_read_response <= 0;
      seen_write_response <= 0;
      stale_waiting <= 0;
      seen_stale_recovery <= 0;
      w_had_command <= 0;
      r_had_command <= 0;
    end else begin
      if (past_valid) begin
        if (previous_resp.r_valid && !previous_req.r_ready) begin
          assert (resp.r_valid);
          assert (resp.r == previous_resp.r);
        end
        if (previous_resp.b_valid && !previous_req.b_ready) begin
          assert (resp.b_valid);
          assert (resp.b == previous_resp.b);
        end
        if (previous_offer && !previous_grant) begin
          assert (mem_req);
          assert ({mem_addr, mem_wdata, mem_be, mem_we, mem_tag} ==
                  {previous_addr, previous_data, previous_be, previous_we, previous_tag});
        end
        if (previous_stale_read) assert (!resp.r_valid);
        if (previous_stale_write) assert (!resp.b_valid);
      end

      if (req_i.aw_valid && resp.aw_ready) begin
        assert (!w_pending);
        w_pending <= 1;
        w_had_command <= 0;
        w_left <= 9'(req_i.aw.len) + 1;
        w_total <= 9'(req_i.aw.len) + 1;
        w_id <= req_i.aw.id;
        w_user <= req_i.aw.user;
        w_bad_start <= req_i.aw.addr < 64'h8000_0000 ||
                       req_i.aw.addr >= 64'h8000_0100 || req_i.aw.lock ||
                       !mem_ready_i || req_i.aw.size > 3 || req_i.aw.burst == 3;
      end
      if (req_i.w_valid && resp.w_ready) begin
        assert (w_pending && w_left > 0);
        w_left <= w_left - 1;
      end
      if (resp.b_valid) begin
        assert (w_pending && w_left == 0);
        assert (resp.b.id == w_id && resp.b.user == w_user);
        assert (resp.b.resp == 0 || resp.b.resp == RespSlvErr);
        if (w_bad_start) assert (resp.b.resp == RespSlvErr);
      end
      if (resp.b_valid && req_i.b_ready) w_pending <= 0;
      if (resp.b_valid && req_i.b_ready && resp.b.resp == 0 && w_had_command)
        seen_write_response <= 1;

      if (req_i.ar_valid && resp.ar_ready) begin
        assert (r_left == 0);
        r_left <= 9'(req_i.ar.len) + 1;
        r_had_command <= 0;
        r_total <= 9'(req_i.ar.len) + 1;
        r_id <= req_i.ar.id;
        r_user <= req_i.ar.user;
        r_bad_start <= req_i.ar.addr < 64'h8000_0000 ||
                       req_i.ar.addr >= 64'h8000_0100 || req_i.ar.lock ||
                       !mem_ready_i || req_i.ar.size > 3 || req_i.ar.burst == 3;
      end
      if (resp.r_valid) begin
        assert (r_left > 0);
        assert (resp.r.id == r_id && resp.r.user == r_user);
        assert (resp.r.last == (r_left == 1));
        assert (resp.r.resp == 0 || resp.r.resp == RespSlvErr);
        if (r_bad_start) assert (resp.r.resp == RespSlvErr);
        if (resp.r.resp == RespSlvErr) assert (resp.r.data == 0);
      end
      if (resp.r_valid && req_i.r_ready) r_left <= r_left - 1;
      if (resp.r_valid && req_i.r_ready && resp.r.last && resp.r.resp == 0 &&
          r_had_command)
        seen_read_response <= 1;

      if (mem_req) begin
        assert (!memory_live);
        assert (mem_addr <= 248 && mem_addr[2:0] == 0 && mem_be != 0);
        assert (mem_tag.source == 8'h3a && mem_tag.reset_generation == 0);
        if (mem_we) begin
          assert (w_pending && !w_bad_start && w_left < w_total);
          assert (mem_tag.axi_id == 16'(w_id));
          assert (mem_tag.beat == 8'(w_total - w_left - 1));
        end else begin
          assert (r_left > 0 && !r_bad_start && !resp.r_valid);
          assert (mem_tag.axi_id == 16'(r_id));
          assert (mem_tag.beat == 8'(r_total - r_left));
        end
      end
      if (mem_req && mem_gnt_i) begin
        assert (mem_tag.seq < 16);
        if (mem_tag.seq < 16) begin
          assert (!seen_sequences[mem_tag.seq[3:0]]);
          seen_sequences[mem_tag.seq[3:0]] <= 1;
        end
        memory_live <= 1;
        memory_write <= mem_we;
        live_tag <= mem_tag;
        stale_waiting <= 0;
        if (mem_we) begin
          seen_write_command <= 1;
          w_had_command <= 1;
        end else begin
          seen_read_command <= 1;
          r_had_command <= 1;
        end
      end
      if (mem_rvalid_i && memory_live && mem_tag_i != live_tag) stale_waiting <= 1;
      if (mem_rvalid_i && memory_live && mem_tag_i == live_tag) begin
        memory_live <= 0;
        if (stale_waiting) seen_stale_recovery <= 1;
        stale_waiting <= 0;
      end
      previous_stale_read <= memory_live && !memory_write &&
                             mem_rvalid_i && mem_tag_i != live_tag;
      previous_stale_write <= memory_live && memory_write &&
                              mem_rvalid_i && mem_tag_i != live_tag;
      previous_offer <= mem_req;
      previous_grant <= mem_gnt_i;
      previous_addr <= mem_addr;
      previous_data <= mem_wdata;
      previous_be <= mem_be;
      previous_we <= mem_we;
      previous_tag <= mem_tag;
      previous_resp <= resp;
      previous_req <= req_i;
      past_valid <= 1;
    end
  end
endmodule
