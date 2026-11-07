// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module formal_g6lc_storamic_checkpoint_io #(
  parameter bit OracleNegative = 1'b0,
  // 0 retains the combined harness; 1/2 partition assertions, not inputs.
  parameter int unsigned PropertyGroup = 0
) (
  input logic clk_i, rst_ni, command_i, ram_i, flush_i, write_i, consume_i,
  input logic [31:0] reset_generation_i,
  input logic [63:0] addr_i, data_i,
  input g6lc_storamic_pkg::txn_id_t reply_tag_i,
  input logic grant_ram_i, finish_ram_i, stale_i, grant_store_i, finish_store_i,
  input logic finish_flush_i, error_i,
  output logic cover_response_o, cover_stale_o, cover_exhausted_o, cover_renew_o
);
  import g6lc_storamic_pkg::*;
  logic ready, response, response_error, exhausted, stale_event;
  logic [63:0] response_data;
  logic mr, mg, mw, mrv, sr, sg, sw, srv, fr, fa;
  logic [63:0] ma, md, sa, sd;
  logic [7:0] mb, sb;
  txn_id_t mt, rt, accepted_tag, previous_tag;
  logic ram_pending, store_pending, flush_pending, flush_seen, reply_mismatch;
  assign mg = mr && grant_ram_i;
  assign sg = sr && grant_store_i;
  assign mrv = ram_pending && finish_ram_i;
  assign srv = store_pending && finish_store_i;
  assign fa = flush_pending && finish_flush_i;
  always_comb begin
    rt = accepted_tag;
    if (stale_i) rt = reply_tag_i;
  end
  assign reply_mismatch = rt != accepted_tag;
  g6lc_storamic_checkpoint_io #(.SeqWidth(1), .EpochWidth(1)) dut (
    .clk_i, .rst_ni, .reset_generation_i, .command_i, .ready_o(ready),
    .ram_i, .flush_i, .write_i, .addr_i, .data_i,
    .response_o(response), .response_ready_i(consume_i), .data_o(response_data),
    .error_o(response_error), .exhausted_o(exhausted), .stale_event_o(stale_event),
    .mem_req_o(mr), .mem_gnt_i(mg), .mem_we_o(mw), .mem_addr_o(ma),
    .mem_wdata_o(md), .mem_be_o(mb), .mem_tag_o(mt), .mem_rvalid_i(mrv),
    .mem_rdata_i(64'hCAFE), .mem_error_i(error_i), .mem_tag_i(rt),
    .st_req_o(sr), .st_gnt_i(sg), .st_we_o(sw), .st_addr_o(sa),
    .st_wdata_o(sd), .st_be_o(sb), .st_rvalid_i(srv), .st_rdata_i(64'hBEEF),
    .st_error_i(error_i), .st_flush_req_o(fr), .st_flush_ack_i(fa),
    .st_flush_error_i(error_i)
  );
  logic active, had_ram, rejected, stale_p, stalled_response;
  logic held_ram, held_store;
  logic [63:0] held_addr, held_data, data_p;
  logic held_write, error_p;
  txn_id_t held_tag;
  logic [2:0] grants;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ram_pending <= 0; store_pending <= 0; flush_pending <= 0; flush_seen <= 0;
      accepted_tag <= '0; previous_tag <= '0; held_tag <= '0;
      active <= 0; had_ram <= 0; rejected <= 0; stale_p <= 0; stalled_response <= 0;
      held_ram <= 0; held_store <= 0; held_addr <= 0; held_data <= 0;
      held_write <= 0; data_p <= 0; error_p <= 0; grants <= 0;
      cover_response_o <= 0; cover_stale_o <= 0; cover_exhausted_o <= 0; cover_renew_o <= 0;
    end else begin
      if (command_i && ready) begin
        if (PropertyGroup != 2) assert (!active);
        active <= 1; rejected <= ram_i && (flush_i || exhausted);
      end
      if (response) begin
        if (PropertyGroup != 2) begin
          assert (active && !mr && !sr && !fr);
          if (rejected) assert (response_error && !ram_pending && !store_pending && !flush_pending);
        end
        if (consume_i) begin active <= 0; cover_response_o <= 1; end
      end
      if (mg) begin
        if (PropertyGroup != 2) begin
          assert (!ram_pending && active && !rejected);
          assert (mt.source == 8'hFE && mt.axi_id == 16'hFFFF && mt.beat == 0);
        end
        if (PropertyGroup != 1 && had_ram) begin
          if (mt.reset_generation == previous_tag.reset_generation)
            assert ({mt.epoch, mt.seq} > {previous_tag.epoch, previous_tag.seq});
          else begin
            assert (mt.reset_generation > previous_tag.reset_generation);
            if (grants == 4) cover_renew_o <= 1;
          end
        end
        if (!had_ram || mt.reset_generation != previous_tag.reset_generation) grants <= 1;
        else if (grants != 4) grants <= grants + 1'b1;
        ram_pending <= 1; accepted_tag <= mt; previous_tag <= mt; had_ram <= 1;
      end
      if (mrv && !reply_mismatch) ram_pending <= 0;
      if (sg) begin
        if (PropertyGroup != 2) assert (!store_pending && active && !rejected);
        store_pending <= 1;
      end
      if (srv) store_pending <= 0;
      if (!fr) flush_seen <= 0;
      if (fr && !flush_seen) begin
        if (PropertyGroup != 2) assert (!flush_pending && active && !rejected);
        flush_pending <= 1; flush_seen <= 1;
      end
      if (fa) flush_pending <= 0;
      if (grants == 4 && exhausted && reset_generation_i == previous_tag.reset_generation)
        cover_exhausted_o <= 1;
      if (stale_event) cover_stale_o <= 1;
      if (PropertyGroup != 2 && stale_p) assert (!response);
      stale_p <= mrv && reply_mismatch;
      if (PropertyGroup != 2 && stalled_response)
        assert (response && response_data == data_p && response_error == error_p);
      stalled_response <= response && !consume_i; data_p <= response_data; error_p <= response_error;
      if (PropertyGroup != 2 && held_ram)
        assert (mr && ma == held_addr && md == held_data && mw == held_write && mt == held_tag);
      if (PropertyGroup != 2 && held_store)
        assert (sr && sa == held_addr && sd == held_data && sw == held_write);
      held_ram <= mr && !mg; held_store <= sr && !sg;
      if (mr || sr) begin
        held_addr <= mr ? ma : sa; held_data <= mr ? md : sd;
        held_write <= mr ? mw : sw; held_tag <= mt;
        if (PropertyGroup != 2) assert ((mr ? mb : sb) == 8'hFF);
      end
      if (OracleNegative) assert (!mr);
    end
  end
  // Assert inductive allocation relations rather than constraining namespace
  // inputs. The two-bit lease is exhausted; all 32 namespace bits stay free.
  if (PropertyGroup == 2) begin : gen_allocation_invariants
    // Slang cannot emit a hierarchical enum constant; pin the helper's
    // IRamWait encoding here so an encoding change requires proof review.
    localparam logic [2:0] RamWaitEncoding = 3'd2;
    logic [1:0] last_nonce, offered_nonce;
    assign last_nonce = {previous_tag.epoch[0], previous_tag.seq[0]};
    assign offered_nonce = {mt.epoch[0], mt.seq[0]};
    always_ff @(posedge clk_i) if (rst_ni) begin
      assert (ram_pending == (dut.state_q == RamWaitEncoding));
      if (ram_pending) assert (accepted_tag == mt);
      if (dut.exhausted_q) assert (&dut.count_q);
      if (had_ram) begin
        assert (previous_tag.epoch[7:1] == 0 && previous_tag.seq[31:1] == 0);
        assert (dut.namespace_q >= previous_tag.reset_generation);
        if (dut.namespace_q == previous_tag.reset_generation)
          assert (dut.count_q > last_nonce ||
                  (dut.exhausted_q && (&last_nonce) && (&dut.count_q)));
      end
      if (mr || ram_pending) begin
        assert (mt.reset_generation == dut.namespace_q);
        assert (mt.epoch[7:1] == 0 && mt.seq[31:1] == 0);
        if (dut.exhausted_q) assert ((&offered_nonce) && (&dut.count_q));
        else assert ({1'b0, dut.count_q} == {1'b0, offered_nonce} + 3'd1);
      end
      if (mr && had_ram) begin
        if (mt.reset_generation == previous_tag.reset_generation)
          assert (offered_nonce > last_nonce);
        else assert (mt.reset_generation > previous_tag.reset_generation);
      end
    end
  end
endmodule
